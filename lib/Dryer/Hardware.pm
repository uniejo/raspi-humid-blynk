package Dryer::Hardware;
use Mojo::Base 'Mojo::EventEmitter', -signatures;

use Mojo::IOLoop;

# Events: button => ($name, $pressed, $time)

has config  => sub { {} };
has outputs => sub { {} };    # name => 0/1, as last written
has 'error';                  # last sensor error

sub output_names ($self) { sort keys %{$self->config->{outputs} // {}} }

sub start ($self) {
  $self->set_output($_ => 0) for $self->output_names;
  return $self;
}

sub stop ($self) {
  $self->set_output($_ => 0) for $self->output_names;
  return $self;
}

# Returns { temperature, humidity } or undef (see error)
sub read_sensor ($self) { die 'read_sensor not implemented' }

sub set_output ($self, $name, $on) {
  return $self unless $self->config->{outputs}{$name};
  $on = $on ? 1 : 0;
  $self->_write($name, $on);
  $self->outputs->{$name} = $on;
  return $self;
}

sub _write ($self, $name, $on) { }

# Pulse an output: on, then toggle after each duration (milliseconds), ending off
sub click ($self, $name, @ms) {
  $self->set_output($name, 1);
  my ($at, $on) = (0, 1);
  for my $ms (@ms) {
    $at += $ms / 1000;
    my $state = $on = !$on;
    Mojo::IOLoop->timer($at => sub { $self->set_output($name, $state) });
  }
  return $self;
}

1;
