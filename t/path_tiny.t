use strict;
use warnings;
use Test::More;

use Git::Wrapper;
use Sort::Versions;
use Test::Deep;

eval 'require Path::Tiny' or plan skip_all =>
    "Path::Tiny is required for this test.";

my $tempdir = Path::Tiny->tempdir;

my $git = Git::Wrapper->new("$tempdir");

my $version = $git->version;
if ( versioncmp( $git->version , '1.5.0') eq -1 ) {
  plan skip_all =>
    "Git prior to v1.5.0 doesn't support 'config' subcmd which we need for this test."
}

diag( "Testing git version: " . $version );

$git->init; # 'git init' also added in v1.5.0 so we're safe

$git->config( 'user.name'  , 'Test User'        );
$git->config( 'user.email' , 'test@example.com' );

# make sure git isn't munging our content so we have consistent hashes
$git->config( 'core.autocrlf' , 'false' );
$git->config( 'core.safecrlf' , 'false' );

my $foo = $tempdir->child('foo');
$foo->mkpath;

$foo->child('bar')->spew(iomode => '>:raw', "hello\n");

is_deeply(
  [ $git->ls_files({ o => 1 }) ],
  [ 'foo/bar' ],
);

$git->add(Path::Tiny::path('.'));
is_deeply(
  [ $git->ls_files ],
  [ 'foo/bar' ],
);

SKIP: {
  skip "Fails on Mac OS X with Git version < 1.7.5 for unknown reasons." , 1
    if (($^O eq 'darwin') and ( versioncmp( $git->version , '1.7.5') eq -1 ));

  $git->commit({ message => "FIRST\n\n\tBODY\n" });

  my $baz = $tempdir->child('baz');

  $baz->spew("world\n");

  $git->add($baz);

  ok(1);
}

done_testing();
