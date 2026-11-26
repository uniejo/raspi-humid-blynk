requires 'perl',        '>= 5.020';
requires 'Mojolicious', '>= 9.34';    # Mojo::File::spew

on test => sub {
  requires 'Test::More', '>= 0.98';
};
