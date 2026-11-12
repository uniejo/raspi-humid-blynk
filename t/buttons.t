use Mojo::Base -strict, -signatures;

use Test::More;
use Dryer::Buttons;

my $b = Dryer::Buttons->new(min_press => 0.015);

is $b->edge(a => 1, 10), undef, 'press returns nothing';
is $b->edge(a => 0, 10.5), 0.5, 'release returns hold time';
is $b->edge(a => 0, 11), undef, 'release without press ignored';

$b->edge(a => 1, 20);
is $b->edge(a => 0, 20.005), undef, 'contact bounce ignored';

$b->edge(a => 1, 30);
$b->edge(b => 1, 30.25);
is $b->edge(b => 0, 30.5), 0.25, 'buttons are tracked separately';
is $b->edge(a => 0, 32), 2, 'long press';

$b->ignore_until(40.5);
$b->edge(a => 1, 40.1);
is $b->edge(a => 0, 40.6), undef, 'press starting during relay surge ignored';
$b->edge(a => 1, 41.25);
is $b->edge(a => 0, 41.5), 0.25, 'later press works';

done_testing;
