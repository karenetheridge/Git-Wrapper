#!/usr/bin/perl

use strict;
use warnings;
use Test::More;
use Test::Fatal;

use File::Temp qw(tempdir);
use Git::Wrapper;

my $dir = tempdir(CLEANUP => 1);

{
  my $git = Git::Wrapper->new({ dir        => $dir ,
                                git_binary => 'echo' });

  my @got = $git->RUN('marco');
  # apparently some versions of windows include extra bonus whitespace, so the
  # simple way of testing this fails sometimes. so...
  is( scalar @got , 1 , 'only get one line' );
  like( $got[0] , qr/^marco\s*$/ , 'Wrapper runs what ever binary we tell it to' );
}

{
  like exception { my $git = Git::Wrapper->new() }, qr/^usage: /, 'need a dir';
  like exception { my $git = Git::Wrapper->new(['foo']) }, qr/^Single arg must be hashref, scalar, or stringify-able object/, 'need to call properly';
  like exception { my $git = Git::Wrapper->new([dir => 'foo']) }, qr/^Single arg must be hashref, scalar, or stringify-able object/, 'no, really, need to call properly';
  like exception { my $git = Git::Wrapper->new({ git_binary => "$dir/echo" }) }, qr/^usage: /, 'just git_binary fails';
}

done_testing();
