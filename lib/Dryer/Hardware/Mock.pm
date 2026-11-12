package Dryer::Hardware::Mock;
use Mojo::Base 'Dryer::Hardware', -signatures;

use Time::HiRes ();

# Simulated dryer for development without a Raspberry Pi

has config => sub {
  {outputs => {heater => {}, fan => {}, clicker => {}, spare => {}}}
};
has ambient     => 20;
has max_heat    => 65;
has temperature => 20;
has humidity    => 60;
has speed       => 10;    # simulated seconds per real second
has 'last_read';

sub read_sensor ($self) {
  my $now  = Time::HiRes::time();
  my $last = $self->last_read // $now;
  $self->last_read($now);
  my $dt = ($now - $last) * $self->speed;

  my $heating = $self->outputs->{heater};
  my $target  = $heating ? $self->max_heat : $self->ambient;
  $self->temperature($target + ($self->temperature - $target) * exp(-$dt / 600));

  my $humid_target = $heating ? 2 : 60;
  $self->humidity($humid_target + ($self->humidity - $humid_target) * exp(-$dt / ($heating ? 900 : 3600)));

  return {temperature => $self->temperature, humidity => $self->humidity};
}

1;
