package Dryer::Hardware::Pi;
use Mojo::Base 'Dryer::Hardware', -signatures;

use File::Spec;
use Mojo::IOLoop;
use Mojo::IOLoop::Stream;
use Time::HiRes ();

# Raspberry Pi hardware (any model, including Pi 5):
#
#   sensor  - kernel "dht11" driver via IIO (dtoverlay=dht11,gpiopin=4), handles DHT11 and DHT22
#   buttons - libgpiod "gpiomon" (v1 or v2) streaming edge events
#   relays  - "pinctrl set <pin> op dh|dl" (or "raspi-gpio", same syntax)

has iio_root  => '/sys/bus/iio/devices';
has stopping  => 0;
has gpiomon_pid => undef;

sub start ($self) {
  $self->SUPER::start;
  $self->stopping(0);
  $self->_monitor;
  return $self;
}

sub stop ($self) {
  $self->stopping(1);
  kill TERM => $self->gpiomon_pid if $self->gpiomon_pid;
  return $self->SUPER::stop;
}

# --- sensor ---------------------------------------------------------------

sub iio_device ($self) {
  return $self->config->{iio_device} if $self->config->{iio_device};
  for my $dir (sort glob($self->iio_root . '/iio:device*')) {
    open my $fh, '<', "$dir/name" or next;
    my $name = <$fh> // '';
    return $dir if $name =~ /dht/;
  }
  return undef;
}

sub read_sensor ($self) {
  my $dir = $self->iio_device;
  unless ($dir) {
    $self->error('No DHT11/DHT22 IIO device found (is dtoverlay=dht11 enabled?)');
    return undef;
  }

  my %reading;
  for my $pair ([temperature => 'in_temp_input'], [humidity => 'in_humidityrelative_input']) {
    my ($key, $file) = @$pair;
    # The driver often answers EIO/ETIMEDOUT when it misses the sensor's reply; just try again next time
    open my $fh, '<', "$dir/$file" or return $self->_sensor_error("$file: $!");
    my $value = <$fh>;
    return $self->_sensor_error("$file: $!") unless defined $value && $value =~ /^(-?\d+)/;
    $reading{$key} = $1 / 1000;
  }
  $self->error(undef);
  return \%reading;
}

sub _sensor_error ($self, $error) {
  $self->error($error);
  return undef;
}

# --- relays ---------------------------------------------------------------

sub _write ($self, $name, $on) {
  my $output = $self->config->{outputs}{$name};
  my $level  = $output->{active_low} ? !$on : $on;
  my @cmd    = ($self->config->{output_command} // 'pinctrl', 'set', $output->{pin}, 'op', $level ? 'dh' : 'dl');
  $self->_run(@cmd) == 0 or warn "Setting $name (GPIO$output->{pin}) failed: @cmd\n";
}

sub _run ($self, @cmd) { system @cmd }

# --- buttons --------------------------------------------------------------

sub gpiomon_version ($self) {
  my $out = qx(gpiomon --version 2>/dev/null) // '';
  return $out =~ /v?(\d+)\.\d+/ ? $1 : undef;
}

sub gpiomon_command ($self, $version) {
  my $config = $self->config;
  my @pins   = map { $_->{pin} } map { $config->{inputs}{$_} } sort keys %{$config->{inputs} // {}};
  my $chip   = $config->{gpiochip} // 'gpiochip0';
  my $bias   = $config->{bias};

  # %o = line offset, %e = edge (1 rising; 0 (v1) or 2 (v2) falling)
  my @cmd
    = $version >= 2
    ? ('gpiomon', '-F', '%o %e', '-c', $chip, ($bias ? ('-b', $bias) : ()), @pins)
    : ('gpiomon', '-F', '%o %e', ($bias ? ('-B', $bias) : ()), $chip, @pins);

  # gpiomon writes to a pipe, so make sure every event is flushed immediately
  unshift @cmd, 'stdbuf', '-oL' if _which('stdbuf');
  return @cmd;
}

sub parse_event ($self, $line) {
  my ($pin, $edge) = $line =~ /^\s*(\d+)\s+(\d+)/ or return;
  my $inputs = $self->config->{inputs} // {};
  for my $name (keys %$inputs) {
    next unless $inputs->{$name}{pin} == $pin;
    my $high = $edge == 1 ? 1 : 0;
    return ($name, $inputs->{$name}{active_low} ? !$high || 0 : $high);
  }
  return;
}

sub _monitor ($self) {
  return unless %{$self->config->{inputs} // {}};

  my $version = $self->gpiomon_version;
  unless ($version) {
    warn "gpiomon not found (apt install gpiod), physical buttons disabled\n";
    return;
  }

  my @cmd = $self->gpiomon_command($version);
  my $pid = open my $fh, '-|', @cmd;
  unless ($pid) {
    warn "Starting @cmd failed: $!\n";
    return;
  }
  $self->gpiomon_pid($pid);

  my $stream = Mojo::IOLoop::Stream->new($fh)->timeout(0);
  my $buffer = '';
  $stream->on(
    read => sub ($stream, $bytes) {
      $buffer .= $bytes;
      while ($buffer =~ s/^([^\n]*)\n//) {
        my ($name, $pressed) = $self->parse_event($1) or next;
        $self->emit(button => $name, $pressed, Time::HiRes::time());
      }
    }
  );
  $stream->on(
    close => sub {
      waitpid $pid, 0;
      $self->gpiomon_pid(undef);
      return if $self->stopping;
      warn "gpiomon exited, restarting in 5 seconds\n";
      Mojo::IOLoop->timer(5 => sub { $self->_monitor unless $self->stopping });
    }
  );
  Mojo::IOLoop->stream($stream);
}

sub _which ($program) {
  for my $dir (File::Spec->path) {
    return "$dir/$program" if -x "$dir/$program";
  }
  return undef;
}

1;
