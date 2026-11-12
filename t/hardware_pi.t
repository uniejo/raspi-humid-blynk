use Mojo::Base -strict, -signatures;

use Test::More;
use Mojo::File qw(tempdir);
use Dryer::Hardware::Pi;

my $config = {
  gpiochip => 'gpiochip0',
  inputs   => {heat_button => {pin => 23, active_low => 1}, day_button => {pin => 17}},
  outputs  => {heater      => {pin => 18}, clicker => {pin => 27, active_low => 1}},
};
my $hw = Dryer::Hardware::Pi->new(config => $config);

subtest 'gpiomon command' => sub {
  my @v1 = grep { $_ ne 'stdbuf' && $_ ne '-oL' } $hw->gpiomon_command(1);
  is_deeply \@v1, ['gpiomon', '-F', '%o %e', 'gpiochip0', 17, 23], 'libgpiod v1';
  my @v2 = grep { $_ ne 'stdbuf' && $_ ne '-oL' } $hw->gpiomon_command(2);
  is_deeply \@v2, ['gpiomon', '-F', '%o %e', '-c', 'gpiochip0', 17, 23], 'libgpiod v2';

  local $config->{bias} = 'pull-up';
  my @bias = grep { $_ ne 'stdbuf' && $_ ne '-oL' } $hw->gpiomon_command(2);
  is_deeply [@bias[5, 6]], ['-b', 'pull-up'], 'bias';
};

subtest 'parse gpiomon events' => sub {
  is_deeply [$hw->parse_event('23 2')], [heat_button => 1], 'active low falling (v2) = pressed';
  is_deeply [$hw->parse_event('23 0')], [heat_button => 1], 'active low falling (v1) = pressed';
  is_deeply [$hw->parse_event('23 1')], [heat_button => 0], 'active low rising = released';
  is_deeply [$hw->parse_event('17 1')], [day_button  => 1], 'active high rising = pressed';
  is_deeply [$hw->parse_event('5 1')],  [],                 'unknown pin';
  is_deeply [$hw->parse_event('junk')], [],                 'junk';
};

subtest 'relay outputs' => sub {
  my @calls;
  no warnings 'redefine';
  local *Dryer::Hardware::Pi::_run = sub ($self, @cmd) { push @calls, "@cmd"; 0 };
  $hw->set_output(heater  => 1);
  $hw->set_output(clicker => 1);
  $hw->set_output(heater  => 0);
  $hw->set_output(missing => 1);
  is_deeply \@calls, ['pinctrl set 18 op dh', 'pinctrl set 27 op dl', 'pinctrl set 18 op dl'], 'commands';
  is_deeply $hw->outputs, {heater => 0, clicker => 1}, 'state tracked';
};

subtest 'IIO sensor' => sub {
  my $root = tempdir;
  my $hw   = Dryer::Hardware::Pi->new(config => {}, iio_root => "$root");
  is $hw->read_sensor, undef, 'no device';
  like $hw->error, qr/dtoverlay=dht11/, 'helpful error';

  $root->child('iio:device0')->make_path->child('name')->spew("mcp3008\n");
  my $dev = $root->child('iio:device1')->make_path;
  $dev->child('name')->spew("dht11\n");
  $dev->child('in_temp_input')->spew("23400\n");
  $dev->child('in_humidityrelative_input')->spew("45100\n");
  is $hw->iio_device, "$dev", 'finds the DHT device';
  is_deeply $hw->read_sensor, {temperature => 23.4, humidity => 45.1}, 'reading';
  is $hw->error, undef, 'no error';

  $dev->child('in_humidityrelative_input')->remove;
  is $hw->read_sensor, undef, 'failed read';
  like $hw->error, qr/in_humidityrelative_input/, 'error names the file';
};

done_testing;
