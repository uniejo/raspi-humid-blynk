package Dryer::Model;
use Mojo::Base 'Mojo::EventEmitter', -signatures;

use Mojo::File qw(path);
use Mojo::JSON qw(decode_json encode_json);
use POSIX qw(strftime);
use Scalar::Util qw(looks_like_number);
use Time::HiRes ();

# Warnings sent for every degree-day timer, relative to its target.
use constant WARNINGS => (
  [-1.0, 'One degree-day remaining'],
  [-0.5, 'Half a degree-day remaining'],
  [0.0,  'Done'],
  [0.5,  'Done half a degree-day ago'],
);

our %LIMITS = (
  req_humid     => [0,   100],
  req_temp_days => [0.5, 1000],
  max_temp      => [0,   80],
);

# Persisted settings
has req_humid     => 10;
has req_temp_days => 40;
has max_temp      => 30;
has timers        => sub { [] };

# Runtime state
has stage       => 'ready';
has stage_since => sub { _now() };
has 'reading';    # { temperature, humidity, time }
has history => sub { [] };    # [ [time, temperature, humidity], ... ]
has notices => sub { [] };    # [ { time, title, body }, ... ] newest first

# Tunables
has 'save_file';
has pause_to_done  => 60;          # seconds humidity must stay low before "done"
has done_to_ready  => 2;
has sensor_timeout => 60;          # heater is paused when readings are older
has history_step   => 60;          # one history point per minute
has history_size   => 24 * 60;     # 24 hours
has notices_size   => 20;

has integrated_at => undef;
has next_id       => 1;

sub _now () { Time::HiRes::time() }

sub valid_setting ($class, $name, $value) {
  my $limit = $LIMITS{$name} or return 0;
  return defined $value
    && !ref $value
    && looks_like_number($value)
    && $value >= $limit->[0]
    && $value <= $limit->[1];
}

sub load ($self) {
  my $file = $self->save_file;
  return $self unless $file && -e $file;

  my $data = eval { decode_json(path($file)->slurp) };
  unless (ref $data eq 'HASH') {
    warn "Ignoring unreadable save file $file: " . ($@ || "not a JSON object\n");
    return $self;
  }

  for my $name (keys %LIMITS) {
    $self->$name(0 + $data->{$name}) if $self->valid_setting($name, $data->{$name});
  }

  # "temp_days_list" is the name used by the old humid_blynk.js save file
  my $timers = $data->{timers} // $data->{temp_days_list};
  my @timers = map { $self->_normalize_timer($_) } grep { ref eq 'HASH' } ref $timers eq 'ARRAY' ? @$timers : ();
  $self->timers([grep {defined} @timers]);

  return $self;
}

sub _normalize_timer ($self, $timer) {
  return undef unless looks_like_number($timer->{started}) && looks_like_number($timer->{temp_days});

  # humid_blynk.js stored JavaScript milliseconds
  for my $key (qw(started etc)) {
    $timer->{$key} /= 1000 if looks_like_number($timer->{$key}) && $timer->{$key} > 1e11;
  }
  $timer->{req_temp_days} = $self->req_temp_days unless looks_like_number($timer->{req_temp_days});
  $timer->{warnings}      = [grep { ref eq 'HASH' && looks_like_number($_->{temp_days}) } @{$timer->{warnings} // []}];
  $timer->{warnings}      = [sort { $a->{temp_days} <=> $b->{temp_days} } @{$timer->{warnings}}];
  return undef unless @{$timer->{warnings}};

  $timer->{id} = $self->next_id;
  $self->next_id($self->next_id + 1);
  return $timer;
}

sub save ($self) {
  my $file = $self->save_file or return $self;
  my $data = {timers => $self->timers, map { $_ => $self->$_ } keys %LIMITS};
  my $tmp  = path("$file.tmp");
  eval {
    $tmp->spew(encode_json($data));
    rename "$tmp", $file or die "rename: $!\n";
    1;
  } or warn "Saving $file failed: $@";
  return $self;
}

sub update_settings ($self, $new) {
  my @errors;
  for my $name (sort keys %$new) {
    if (!$LIMITS{$name}) { push @errors, "Unknown setting '$name'" }
    elsif (!$self->valid_setting($name, $new->{$name})) {
      push @errors, "$name must be a number between $LIMITS{$name}[0] and $LIMITS{$name}[1]";
    }
  }
  return \@errors if @errors;

  $self->$_(0 + $new->{$_}) for keys %$new;
  $self->save->emit('changed');
  return [];
}

sub set_stage ($self, $stage, $now = _now()) {
  my $old = $self->stage;
  return $self if $old eq $stage;
  $self->stage($stage)->stage_since($now);
  return $self->emit(stage => $stage, $old)->emit('changed');
}

sub is_idle ($self) { $self->stage eq 'ready' || $self->stage eq 'done' }

sub start ($self, $now = _now()) { $self->set_stage(heating => $now) }
sub stop  ($self, $now = _now()) { $self->set_stage(ready   => $now) }

sub sensor_fresh ($self, $now = _now()) {
  my $reading = $self->reading;
  return $reading && $now - $reading->{time} <= $self->sensor_timeout;
}

# Run the drying state machine, called once a second
sub tick ($self, $now = _now()) {
  my $stage    = $self->stage;
  my $in_stage = $now - $self->stage_since;

  if ($stage eq 'done') {
    $self->set_stage(ready => $now) if $in_stage >= $self->done_to_ready;
    return $self;
  }
  return $self if $stage eq 'ready';

  # Never heat blind
  unless ($self->sensor_fresh($now)) {
    if ($stage eq 'heating') {
      $self->set_stage(pause => $now);
      $self->notice('Sensor lost', 'No sensor reading for ' . $self->sensor_timeout . ' seconds, heater paused.', $now)
        if $self->reading;
    }
    return $self;
  }

  my $reading = $self->reading;
  if ($reading->{humidity} <= $self->req_humid) {
    if ($stage eq 'pause' && $in_stage > $self->pause_to_done) {
      $self->set_stage(done => $now);
      $self->notice('Drying done', sprintf('Humidity %.1f%% reached (target %s%%).', $reading->{humidity}, $self->req_humid), $now);
    }
    elsif ($stage eq 'heating') { $self->set_stage(pause => $now) }
  }
  elsif ($reading->{temperature} < $self->max_temp) { $self->set_stage(heating => $now) }
  else                                               { $self->set_stage(pause   => $now) }

  return $self;
}

sub add_reading ($self, $temperature, $humidity, $now = _now()) {
  $self->reading({temperature => $temperature, humidity => $humidity, time => $now});
  $self->_integrate($temperature, $now);

  my $history = $self->history;
  my $step    = $self->history_step;
  if (!@$history || int($history->[-1][0] / $step) != int($now / $step)) {
    push @$history, [$now, $temperature, $humidity];
    splice @$history, 0, @$history - $self->history_size if @$history > $self->history_size;
  }

  return $self->emit('changed');
}

# Add degree-days (base 0°C) to every timer and send the warnings that are due
sub _integrate ($self, $temperature, $now) {
  my $last = $self->integrated_at;
  $self->integrated_at($now);
  return unless defined $last && @{$self->timers};

  my $delta = $temperature * ($now - $last) / 86400;
  my (@notices, @keep);
  for my $timer (@{$self->timers}) {
    $timer->{temp_days} += $delta;

    my $days = ($now - $timer->{started}) / 86400;
    if ($days > 0 && $timer->{temp_days} > 0) {
      $timer->{day_avg} = $timer->{temp_days} / $days;
      $timer->{etc}     = $timer->{started} + $timer->{req_temp_days} / $timer->{day_avg} * 86400;
    }

    my $warnings = $timer->{warnings};
    while (@$warnings && $warnings->[0]{temp_days} <= $timer->{temp_days}) {
      my $warning = shift @$warnings;
      push @notices,
        sprintf("Timer #%d: %s\n%.2f of %s degree-days\nStarted: %s\nETC: %s",
        $timer->{id}, $warning->{text}, $timer->{temp_days}, $timer->{req_temp_days},
        _time($timer->{started}), _time($timer->{etc}));
    }
    push @keep, $timer if @$warnings;
  }
  $self->timers(\@keep);
  return unless @notices;

  $self->emit(click => 'warning');
  $self->notice('Degree-day timer', join("\n\n", @notices, $self->summary), $now);
  $self->save;
}

sub add_timer ($self, $now = _now()) {
  my $req   = $self->req_temp_days;
  my $timer = {
    id            => $self->next_id,
    started       => $now,
    temp_days     => 0,
    req_temp_days => $req,
    warnings      => [map { {temp_days => $req + $_->[0], text => $_->[1]} } grep { $req + $_->[0] > 0 } WARNINGS],
  };
  $self->next_id($self->next_id + 1);
  push @{$self->timers}, $timer;
  $self->emit(click => 'ack')->save->emit('changed');
  return $timer;
}

sub remove_timer ($self, $which) {
  my $timers  = $self->timers;
  my $removed = $which eq 'oldest' ? shift @$timers : pop @$timers;
  $self->emit(click => 'ack')->save->emit('changed') if $removed;
  return $removed;
}

sub notice ($self, $title, $body, $now = _now()) {
  my $notices = $self->notices;
  unshift @$notices, {time => $now, title => $title, body => $body};
  splice @$notices, $self->notices_size if @$notices > $self->notices_size;
  return $self->emit(notice => $title, $body)->emit('changed');
}

sub summary ($self) {
  my @timers = @{$self->timers};
  return 'No active timers.' unless @timers;
  my ($first) = sort { ($a->{etc} // 9e99) <=> ($b->{etc} // 9e99) } @timers;
  return sprintf("%d active: %s\nNext ETC: %s",
    scalar @timers, join(', ', map { sprintf '%.2f', $_->{temp_days} } @timers), _time($first->{etc}));
}

sub snapshot ($self, $now = _now()) {
  my $reading = $self->reading;
  return {
    now         => $now,
    stage       => $self->stage,
    stage_since => $self->stage_since,
    reading     => $reading ? {%$reading, stale => $self->sensor_fresh($now) ? 0 : 1} : undef,
    settings    => {map { $_ => $self->$_ } keys %LIMITS},
    limits      => \%LIMITS,
    notices     => $self->notices,
    timers      => [
      map {
        {
          id            => $_->{id},
          started       => $_->{started},
          temp_days     => $_->{temp_days},
          req_temp_days => $_->{req_temp_days},
          etc           => $_->{etc},
          next_warning  => $_->{warnings}[0],
        }
      } @{$self->timers}
    ],
  };
}

sub _time ($epoch) { defined $epoch ? strftime('%Y-%m-%d %H:%M', localtime $epoch) : '-' }

1;
