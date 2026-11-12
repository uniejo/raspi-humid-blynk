package Dryer::Controller::Api;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub show ($c) { $c->render(json => $c->model->snapshot) }

sub history ($c) { $c->render(json => $c->model->history) }

sub start_heat ($c) {
  $c->model->start;
  $c->show;
}

sub stop_heat ($c) {
  $c->model->stop;
  $c->show;
}

sub add_timer ($c) {
  $c->model->add_timer;
  $c->show;
}

sub remove_timer ($c) {
  return $c->render(json => {errors => ['No timers']}, status => 404)
    unless $c->model->remove_timer($c->param('which'));
  $c->show;
}

sub settings ($c) {
  my $new = $c->req->json;
  return $c->render(json => {errors => ['Expected a JSON object']}, status => 400) unless ref $new eq 'HASH';
  my $errors = $c->model->update_settings($new);
  return $c->render(json => {errors => $errors}, status => 400) if @$errors;
  $c->show;
}

sub ws ($c) {
  $c->inactivity_timeout(300);
  my $model = $c->model;
  my $send  = $model->on(changed => sub { $c->send({json => $model->snapshot}) });
  $c->on(finish => sub { $model->unsubscribe(changed => $send) });
  $c->send({json => $model->snapshot});
}

1;
