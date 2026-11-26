package Dryer::Notifier;
use Mojo::Base -base, -signatures;

use Mojo::Util qw(encode);

# Sends notices to ntfy (https://ntfy.sh or self-hosted) and/or email via sendmail

has config => sub { {} };
has 'log';
has 'ua';

sub send ($self, $title, $body) {
  my $config = $self->config;
  $self->log->info("Notice: $title: " . ($body =~ s/\n+/ | /gr));

  if (my $url = $config->{ntfy}) {
    $self->ua->post_p($url => {Title => $title} => encode('UTF-8', $body))->then(sub ($tx) {
      $self->log->warn("ntfy failed: " . $tx->res->code) if $tx->res->is_error;
    })->catch(sub ($err) { $self->log->warn("ntfy failed: $err") });
  }

  if (my $to = $config->{email}) {
    my $sendmail = $config->{sendmail} // '/usr/sbin/sendmail';
    if (open my $mail, '|-', $sendmail, '-t', '-oi') {
      my $from = $config->{from} // 'dryer';
      print {$mail} encode('UTF-8', "To: $to\nFrom: $from\nSubject: Dryer: $title\n"
          . "Content-Type: text/plain; charset=UTF-8\n\n$body\n");
      close $mail or $self->log->warn("sendmail exited with status $?");
    }
    else { $self->log->warn("Running $sendmail failed: $!") }
  }

  return $self;
}

1;
