package Dryer;
use Mojo::Base 'Mojolicious', -signatures;
use utf8;

use Dryer::Buttons;
use Dryer::Model;
use Dryer::Notifier;
use Mojo::IOLoop;
use Mojo::Loader qw(load_class);
use Mojo::Util qw(secure_compare);
use Time::HiRes ();

our $VERSION = '2.00';

my %DEFAULTS = (
  hardware        => 'Mock',                # "Pi" on a Raspberry Pi
  save_file       => 'dryer-state.json',    # relative to the app home
  password        => undef,                 # HTTP basic auth (any user name)
  sensor_interval => 5,
  pause_to_done   => 60,
  sensor_timeout  => 60,
  eta_window      => 1800,
  settings        => {req_humid => 10, req_temp_days => 40, max_temp => 30},    # used until saved
  buttons         => {min_press => 0.015, heat_long_press => 1.5, day_long_press => 1.0, ignore_after_switch => 0.5},
  pi              => {
    gpiochip       => 'gpiochip0',
    output_command => 'pinctrl',
    bias           => undef,
    iio_device     => undef,
    inputs         => {heat_button => {pin => 23, active_low => 1}, day_button => {pin => 17, active_low => 1}},
    outputs => {heater => {pin => 18}, fan => {pin => 24}, clicker => {pin => 27}, spare => {pin => 22}},
  },
  notify => {ntfy => undef, email => undef, sendmail => '/usr/sbin/sendmail', from => 'dryer'},
);

sub startup ($self) {
  my $file = $ENV{DRYER_CONFIG} // $self->home->child('dryer.conf');
  my $user = $self->config->{config_override} || -e $file ? $self->plugin(Config => {file => $file}) : {};
  my $config = {%DEFAULTS, %$user};
  for my $key (grep { ref $DEFAULTS{$_} eq 'HASH' } keys %DEFAULTS) {
    $config->{$key} = {%{$DEFAULTS{$key}}, %{$user->{$key} // {}}};
  }
  $self->config($config);
  $self->secrets([$config->{secret} // 'dryer-' . ($config->{password} // 'no-session-data')]);

  my $model = Dryer::Model->new(
    %{$config->{settings}},
    save_file      => _abs($self->home, $config->{save_file}),
    pause_to_done  => $config->{pause_to_done},
    sensor_timeout => $config->{sensor_timeout},
    eta_window     => $config->{eta_window},
  )->load;

  my $class = "Dryer::Hardware::$config->{hardware}";
  die ref $_ ? $_ : "Unknown hardware '$config->{hardware}'\n" for grep {$_} load_class $class;
  my $hardware = $class eq 'Dryer::Hardware::Pi' ? $class->new(config => $config->{pi}) : $class->new;

  my $buttons  = Dryer::Buttons->new(min_press => $config->{buttons}{min_press});
  my $notifier = Dryer::Notifier->new(config => $config->{notify}, log => $self->log, ua => $self->ua);

  $self->helper(model    => sub {$model});
  $self->helper(hardware => sub {$hardware});
  $self->helper(notifier => sub {$notifier});

  $self->_wire($model, $hardware, $buttons, $notifier);
  $self->hook(before_server_start => sub { $self->_start_loops });

  $self->_routes;
}

sub _wire ($self, $model, $hardware, $buttons, $notifier) {
  my $cfg = $self->config->{buttons};

  $model->on(
    stage => sub ($model, $stage, $old) {
      my $r = $model->reading;
      $self->log->info("Stage $old -> $stage"
          . ($r ? sprintf(' (%.1f°C, %.1f%%%s)', $r->{temperature}, $r->{humidity}, $model->sensor_fresh ? '' : ', stale') : ' (no reading)'));
      my $heat = $stage eq 'heating' ? 1 : 0;
      return if ($hardware->outputs->{heater} // 0) == $heat;
      $hardware->set_output(heater => $heat);

      # Switching the heater can cause a surge that looks like a button press
      $buttons->ignore_until(Time::HiRes::time() + $cfg->{ignore_after_switch});
    }
  );
  $model->on(click  => sub ($model, $kind)  { $hardware->click(clicker => $kind eq 'warning' ? (500, 1000, 500) : 500) });
  $model->on(notice => sub ($model, @args)  { $notifier->send(@args) });

  $hardware->on(
    button => sub ($hardware, $name, $pressed, $now) {
      my $held = $buttons->edge($name, $pressed, $now) // return;
      $self->log->debug(sprintf '%s held %.3fs', $name, $held);
      if ($name eq 'heat_button') {
        $held < $cfg->{heat_long_press} ? $model->start : $model->stop;
      }
      elsif ($name eq 'day_button') {
        $held < $cfg->{day_long_press} ? $model->add_timer : $model->remove_timer('newest');
      }
    }
  );
}

sub _start_loops ($self) {
  return if $self->{loops_started}++;
  my ($model, $hardware) = ($self->model, $self->hardware);

  $hardware->start;
  my $read = sub {
    if (my $r = $hardware->read_sensor) { $model->add_reading($r->{temperature}, $r->{humidity}) }
    else                                { $self->log->debug('Sensor: ' . ($hardware->error // 'no reading')) }
  };
  Mojo::IOLoop->recurring($self->config->{sensor_interval} => $read);
  Mojo::IOLoop->recurring(1   => sub { $model->tick });
  Mojo::IOLoop->recurring(900 => sub { $model->save });
  Mojo::IOLoop->next_tick($read);

  # Relays keep their state after the process exits, so always switch them off
  for my $signal (qw(INT TERM)) {
    $SIG{$signal} = sub {
      $self->log->info("Caught SIG$signal, switching outputs off");
      $hardware->stop;
      $model->save;
      exit 0;
    };
  }
  $self->log->info("Dryer $VERSION started with " . ref($hardware) . ' hardware');
}

sub _abs ($home, $file) { Mojo::File::path($file)->is_abs ? $file : $home->rel_file($file)->to_string }

sub _routes ($self) {
  my $r = $self->routes;
  $r->namespaces(['Dryer::Controller']);

  my $auth = $r->under(
    '/' => sub ($c) {
      my $password = $c->config->{password} // return 1;
      return 1 if secure_compare($c->req->url->to_abs->password // '', $password);
      $c->res->headers->www_authenticate('Basic realm="dryer"');
      $c->render(text => 'Authentication required', status => 401);
      return undef;
    }
  );

  $auth->get('/')->to(template => 'index');

  my $api = $auth->any('/api')->to(controller => 'api');
  $api->get('/state')->to('#show');
  $api->get('/history')->to('#history');
  $api->post('/heat/start')->to('#start_heat');
  $api->post('/heat/stop')->to('#stop_heat');
  $api->post('/timers')->to('#add_timer');
  $api->delete('/timers/:which' => [which => [qw(newest oldest)]])->to('#remove_timer');
  $api->put('/settings')->to('#settings');

  $auth->websocket('/ws')->to('api#ws');
}

1;
