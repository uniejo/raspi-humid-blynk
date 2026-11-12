use Mojo::Base -strict, -signatures;

use Test::More;
use Mojo::File qw(tempdir);
use Mojo::JSON qw(decode_json encode_json);
use Dryer::Model;

my $dir = tempdir;
my $T0  = 1_700_000_000;

sub model (%args) { Dryer::Model->new(stage_since => $T0, %args) }

subtest 'stage machine' => sub {
  my $m = model(req_humid => 10, max_temp => 30);
  my @stages;
  $m->on(stage => sub ($m, $stage, $old) { push @stages, $stage });

  $m->tick($T0);
  is $m->stage, 'ready', 'idle until started';

  $m->start($T0);
  $m->add_reading(20, 50, $T0);
  $m->tick($T0);
  is $m->stage, 'heating', 'humid and cool: heat';

  $m->add_reading(31, 40, $T0 + 5);
  $m->tick($T0 + 5);
  is $m->stage, 'pause', 'over max temperature: pause';

  $m->add_reading(29, 40, $T0 + 10);
  $m->tick($T0 + 10);
  is $m->stage, 'heating', 'cooled down: heat again';

  $m->add_reading(29, 9, $T0 + 15);
  $m->tick($T0 + 15);
  is $m->stage, 'pause', 'target humidity reached: pause';

  $m->add_reading(29, 9, $T0 + 50);
  $m->tick($T0 + 50);
  is $m->stage, 'pause', 'still waiting for humidity to stay low';

  my @notices;
  $m->on(notice => sub ($m, $title, $body) { push @notices, $title });
  $m->add_reading(29, 9, $T0 + 80);
  $m->tick($T0 + 80);
  is $m->stage, 'done', 'humidity stayed low: done';
  is_deeply \@notices, ['Drying done'], 'done notice sent';

  $m->tick($T0 + 83);
  is $m->stage, 'ready', 'back to ready';
  is_deeply \@stages, [qw(heating pause heating pause done ready)], 'stage events';
};

subtest 'never heat without fresh readings' => sub {
  my $m = model(sensor_timeout => 60);
  $m->start($T0);
  $m->tick($T0);
  is $m->stage, 'pause', 'no reading at all: do not heat';

  my @notices;
  $m->on(notice => sub ($m, $title, $body) { push @notices, $title });
  $m->add_reading(20, 50, $T0 + 1);
  $m->tick($T0 + 1);
  is $m->stage, 'heating', 'reading arrived: heat';
  $m->tick($T0 + 62);
  is $m->stage, 'pause', 'sensor went quiet: heater paused';
  is_deeply \@notices, ['Sensor lost'], 'and a notice was sent';
  is $m->snapshot($T0 + 62)->{reading}{stale}, 1, 'snapshot marks reading stale';
};

subtest 'degree-day timer warnings fire one at a time, in order' => sub {
  my $m = model(req_temp_days => 2);
  my (@notices, @clicks);
  $m->on(notice => sub ($m, $title, $body) { push @notices, $body });
  $m->on(click  => sub ($m, $kind)        { push @clicks, $kind });

  $m->add_timer($T0);
  is_deeply \@clicks, ['ack'], 'acknowledge click';
  is_deeply [map { $_->{temp_days} } @{$m->timers->[0]{warnings}}], [1, 1.5, 2, 2.5], 'warnings';

  # 20°C for one day = 20 degree-days per day; 1 degree-day = 0.05 day = 4320 s
  $m->add_reading(20, 50, $T0);
  $m->add_reading(20, 50, $T0 + 4320 + 1);
  is scalar @notices, 1, 'only the first warning';
  like $notices[0], qr/One degree-day remaining/, 'first warning text';
  is scalar @{$m->timers->[0]{warnings}}, 3, 'three warnings left';
  ok $m->timers->[0]{etc}, 'ETC computed';

  $m->add_reading(20, 50, $T0 + 3 * 4320 / 2 + 1);
  like $notices[1], qr/Half a degree-day remaining/, 'second warning';
  $m->add_reading(20, 50, $T0 + 2 * 4320 + 1);
  like $notices[2], qr/Timer #1: Done\n/, 'done warning';
  is scalar @{$m->timers}, 1, 'timer still active';
  $m->add_reading(20, 50, $T0 + 5 * 4320 / 2 + 1);
  like $notices[3], qr/Done half a degree-day ago/, 'last warning';
  is scalar @{$m->timers}, 0, 'timer removed after its last warning';
  is_deeply \@clicks, [qw(ack warning warning warning warning)], 'clicks';
};

subtest 'small targets skip warnings below zero' => sub {
  my $m = model(req_temp_days => 0.75);
  is_deeply [map { $_->{temp_days} } @{$m->add_timer($T0)->{warnings}}], [0.25, 0.75, 1.25], 'warnings';
};

subtest 'remove newest/oldest' => sub {
  my $m = model;
  $m->add_timer($T0 + $_) for 1 .. 3;
  is $m->remove_timer('newest')->{id}, 3, 'newest';
  is $m->remove_timer('oldest')->{id}, 1, 'oldest';
  is_deeply [map { $_->{id} } @{$m->timers}], [2], 'left';
  $m->remove_timer('newest');
  is $m->remove_timer('newest'), undef, 'nothing to remove';
};

subtest 'settings' => sub {
  my $m = model;
  is_deeply $m->update_settings({req_humid => 15, max_temp => '35.5'}), [], 'valid';
  is $m->req_humid, 15,   'req_humid';
  is $m->max_temp,  35.5, 'max_temp';
  my $errors = $m->update_settings({req_humid => 101, max_temp => 'hot', nope => 1});
  is scalar @$errors, 3, 'three errors';
  is $m->req_humid, 15, 'unchanged after errors';
};

subtest 'save and load' => sub {
  my $file = $dir->child('state.json')->to_string;
  my $m    = model(save_file => $file, req_humid => 12);
  $m->add_timer($T0);
  $m->add_timer($T0 + 1);
  ok -e $file,        'saved';
  ok !-e "$file.tmp", 'no temp file left behind';

  my $loaded = model(save_file => $file)->load;
  is $loaded->req_humid, 12, 'setting restored';
  is_deeply [map { $_->{id} } @{$loaded->timers}], [1, 2], 'timers restored';
  is $loaded->add_timer($T0 + 2)->{id}, 3, 'ids continue';

  $dir->child('bad.json')->spew('{nope');
  my $warning;
  local $SIG{__WARN__} = sub { $warning = shift };
  my $bad = model(save_file => $dir->child('bad.json')->to_string, req_humid => 7)->load;
  like $warning, qr/Ignoring unreadable save file/, 'warns on broken file';
  is $bad->req_humid, 7, 'keeps defaults';
};

subtest 'load the old humid_blynk.js save file' => sub {
  my $file = $dir->child('humid_blynk.json');
  $file->spew(encode_json {
    req_humid      => 11,
    req_temp_days  => 30,
    max_temp       => 32,
    temp_days_list => [{
      started       => $T0 * 1000,
      etc           => ($T0 + 86400) * 1000,
      temp_days     => 5.5,
      req_temp_days => 30,
      warnings      => [{temp_days => 29, text => 'One dgd remaining'}, {temp_days => 30, text => 'Done'}],
    }],
  });
  my $m = model(save_file => $file->to_string)->load;
  is $m->req_humid,     11, 'req_humid';
  is $m->req_temp_days, 30, 'req_temp_days (was lost by the old script)';
  is $m->max_temp,      32, 'max_temp';
  is $m->timers->[0]{started}, $T0, 'milliseconds converted to seconds';
  is $m->timers->[0]{etc}, $T0 + 86400, 'etc converted';
  is $m->timers->[0]{id},  1,           'id assigned';
};

subtest 'history keeps one point per step' => sub {
  my $m = model(history_step => 60, history_size => 3);
  $m->add_reading(20, 50, $T0 + $_ * 20) for 0 .. 11;
  is scalar @{$m->history}, 3, 'trimmed to size';
  is $m->history->[-1][0] % 60, 0, 'first reading of each step';
};

done_testing;
