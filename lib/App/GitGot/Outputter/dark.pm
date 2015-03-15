package App::GitGot::Outputter::dark;

# ABSTRACT: Color scheme appropriate for dark terminal backgrounds
use 5.014;
use feature 'unicode_strings';

use Types::Standard -types;

use App::GitGot::Types;

use Moo;
extends 'App::GitGot::Outputter';
use namespace::autoclean;

has color_error => (
  is      => 'ro' ,
  isa     => Str ,
  default => 'bold white on_red'
);

has color_major_change => (
  is      => 'ro' ,
  isa     => Str ,
  default => 'bold black on_green'
);

has color_minor_change => (
  is      => 'ro' ,
  isa     => Str ,
  default => 'green'
);

has color_warning => (
  is      => 'ro' ,
  isa     => Str ,
  default => 'bold black on_yellow'
);

1;
