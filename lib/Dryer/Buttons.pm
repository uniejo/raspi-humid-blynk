package Dryer::Buttons;
use Mojo::Base -base, -signatures;

has min_press    => 0.015;    # shorter presses are contact bounce
has ignore_until => 0;        # presses starting before this time are ignored (relay surge)
has down         => sub { {} };

# Feed a button edge; returns the hold time in seconds when a valid press is released
sub edge ($self, $name, $pressed, $now) {
  if ($pressed) {
    $self->down->{$name} = $now;
    return undef;
  }
  my $since = delete $self->down->{$name};
  return undef unless defined $since && $since >= $self->ignore_until;
  my $held = $now - $since;
  return $held >= $self->min_press ? $held : undef;
}

1;
