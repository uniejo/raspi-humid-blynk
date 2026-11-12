use Mojo::Base -strict, -signatures;

use Test::More;
use Test::Mojo;
use Mojo::File qw(tempdir);
use Time::HiRes ();

my $dir = tempdir;
my %config = (hardware => 'Mock', save_file => $dir->child('state.json')->to_string, sensor_interval => 3600);

my $t = Test::Mojo->new(Dryer => {%config});
my $app = $t->app;

subtest 'page and state' => sub {
  $t->get_ok('/')->status_is(200)->text_is(title => 'Dryer')->element_exists('#stages');
  $t->get_ok('/dryer.js')->status_is(200);
  $t->get_ok('/api/state')->status_is(200)->json_is('/stage' => 'ready')->json_is('/settings/req_humid' => 10)
    ->json_is('/timers' => []);
};

subtest 'heat start/stop drives the heater relay' => sub {
  $t->post_ok('/api/heat/start')->status_is(200)->json_is('/stage' => 'heating');
  is $app->hardware->outputs->{heater}, 1, 'heater on';
  $t->post_ok('/api/heat/stop')->status_is(200)->json_is('/stage' => 'ready');
  is $app->hardware->outputs->{heater}, 0, 'heater off';
};

subtest 'timers' => sub {
  $t->post_ok('/api/timers')->status_is(200)->json_is('/timers/0/id' => 1)->json_is('/timers/0/req_temp_days' => 40);
  $t->post_ok('/api/timers')->json_is('/timers/1/id' => 2);
  $t->delete_ok('/api/timers/oldest')->status_is(200)->json_is('/timers/0/id' => 2);
  $t->delete_ok('/api/timers/newest')->status_is(200)->json_is('/timers' => []);
  $t->delete_ok('/api/timers/newest')->status_is(404);
  $t->delete_ok('/api/timers/all')->status_is(404);
};

subtest 'settings' => sub {
  $t->put_ok('/api/settings' => json => {req_humid => 20, max_temp => 40})->status_is(200)
    ->json_is('/settings/req_humid' => 20)->json_is('/settings/max_temp' => 40);
  $t->put_ok('/api/settings' => json => {req_humid => 200})->status_is(400)->json_like('/errors/0' => qr/req_humid/);
  $t->put_ok('/api/settings' => json => [1])->status_is(400);
  ok -e $config{save_file}, 'settings saved';
};

subtest 'physical buttons' => sub {
  my $hw  = $app->hardware;
  my $now = Time::HiRes::time() + 1;    # past the relay-surge ignore window
  $hw->emit(button => heat_button => 1, $now);
  $hw->emit(button => heat_button => 0, $now + 0.2);
  is $app->model->stage, 'heating', 'short press starts heating';

  $now += 10;
  $hw->emit(button => day_button => 1, $now);
  $hw->emit(button => day_button => 0, $now + 0.3);
  is scalar @{$app->model->timers}, 1, 'short press adds a timer';
  $hw->emit(button => day_button => 1, $now + 1);
  $hw->emit(button => day_button => 0, $now + 3);
  is scalar @{$app->model->timers}, 0, 'long press removes it';

  $hw->emit(button => heat_button => 1, $now + 5);
  $hw->emit(button => heat_button => 0, $now + 7);
  is $app->model->stage, 'ready', 'long press stops';
};

subtest 'websocket pushes changes' => sub {
  $t->websocket_ok('/ws')->message_ok->json_message_is('/stage' => 'ready');
  $app->model->start;
  $t->message_ok->json_message_is('/stage' => 'heating');
  $t->finish_ok;
  $app->model->stop;
};

subtest 'password' => sub {
  my $t = Test::Mojo->new(Dryer => {%config, password => 's3cret'});
  $t->get_ok('/')->status_is(401)->header_like('WWW-Authenticate' => qr/Basic/);
  $t->get_ok('/api/state')->status_is(401);
  $t->get_ok('//any:wrong@/')->status_is(401);
  $t->get_ok('//any:s3cret@/')->status_is(200);
};

done_testing;
