use 5.006;
use strict;
use warnings;

package Git::Wrapper;
#ABSTRACT: Wrap git(7) command-line interface

our $DEBUG=0;

# Prevent ANSI color with extreme prejudice
# https://github.com/genehack/Git-Wrapper/issues/13
undef $ENV{GIT_PAGER_IN_USE};

use File::pushd;
use File::Temp;
use IPC::Cmd        qw(can_run);
use IPC::Open3      qw();
use Sort::Versions;
use Symbol;

use Git::Wrapper::Exception;
use Git::Wrapper::File::RawModification;
use Git::Wrapper::Log;
use Git::Wrapper::Statuses;

my $GIT = ( defined $ENV{GIT_WRAPPER_GIT} ) ? $ENV{GIT_WRAPPER_GIT} : 'git';

sub new {
  my ($class, $arg, %opt) = @_;

  my $self = bless { dir => $arg, %opt } => $class;

  die "usage: $class->new(\$dir)" unless $self->dir;

  return $self;
}

sub has_git_in_path { can_run('git') }

sub dir { shift->{dir} }

sub ERR { shift->{err} }
sub OUT { shift->{out} }

sub _opt {
  my $name = shift;
  $name =~ tr/_/-/;
  return length($name) == 1
    ? "-$name"
    : "--$name"
  ;
}

sub RUN {
  my $self = shift;

  delete $self->{err};
  delete $self->{out};

  my $cmd = shift;

  my $opt = ref $_[0] eq 'HASH' ? shift : {};

  my @cmd = $GIT;

  my $stdin = delete $opt->{-STDIN};

  for (grep { /^-/ } keys %$opt) {
    (my $name = $_) =~ s/^-//;

    my $val = delete $opt->{$_};
    next if $val eq '0';

    push @cmd, _opt($name) . _munge_val($name, $val);
  }

  push @cmd, $cmd;

  for my $name (keys %$opt) {
    my $val = delete $opt->{$name};
    next if $val eq '0';

    ( $name, $val ) = $self->_message_tempfile( $val )
      if $self->_win32_multiline_commit_msg( $cmd, $name, $val );

    push @cmd,  _opt($name) . _munge_val($name, $val);
  }

  push @cmd, @_;

  my( @out , @err );

  {
    my $d = pushd $self->dir unless $cmd eq 'clone';

    my ($wtr, $rdr, $err);

    local *TEMP;
    if ($^O eq 'MSWin32' && defined $stdin) {
      my $file = File::Temp->new;
      $file->autoflush(1);
      $file->print($stdin);
      $file->seek(0,0);
      open TEMP, '<&=', $file;
      $wtr = '<&TEMP';
      undef $stdin;
    }

    $err = Symbol::gensym;

    print STDERR join(' ',@cmd),"\n" if $DEBUG;

    my $pid = IPC::Open3::open3($wtr, $rdr, $err, @cmd);
    print $wtr $stdin
      if defined $stdin;

    close $wtr;
    chomp(@out = <$rdr>);
    chomp(@err = <$err>);

    waitpid $pid, 0;
  };

  print "status: $?\n" if $DEBUG;

  # In earlier gits (1.5, 1.6, I'm not sure when it changed), "git status"
  # would exit 1 if there was nothing to commit, or in other cases.  This is
  # basically insane, and has been fixed, but if we don't require git 1.7, we
  # should cope with it. -- rjbs, 2012-03-31
  my $stupid_status = $cmd eq 'status' && @out && ! @err;

  if ($? && ! $stupid_status) {
    die Git::Wrapper::Exception->new(
      output => \@out,
      error  => \@err,
      status => $? >> 8,
    );
  }

  chomp(@err);
  $self->{err} = \@err;

  chomp(@out);
  $self->{out} = \@out;

  return @out;
}

sub _munge_val {
  my( $name , $val ) = @_;

  return $val eq '1'       ? ""
    : length($name) == 1 ? $val
    :                      "=$val";
}

sub _win32_multiline_commit_msg {
  my ( $self, $cmd, $name, $val ) = @_;

  return 0 if $^O ne "MSWin32";
  return 0 if $cmd ne "commit";
  return 0 if $name ne "m" and $name ne "message";
  return 0 if $val !~ /\n/;

  return 1;
}

sub _message_tempfile {
  my ( $self, $message ) = @_;

  my $tmp = File::Temp->new( UNLINK => 0 );
  $tmp->print( $message );

  return ( "file", '"'.$tmp->filename.'"' );
}

sub AUTOLOAD {
  my $self = shift;

  (my $meth = our $AUTOLOAD) =~ s/.+:://;
  return if $meth eq 'DESTROY';

  $meth =~ tr/_/-/;

  return $self->RUN($meth, @_);
}

sub version {
  my $self = shift;

  my ($version) = $self->RUN('version');

  $version =~ s/^git version //;

  return $version;
}

sub log {
  my $self = shift;

  my $opt  = ref $_[0] eq 'HASH' ? shift : {};
  $opt->{no_color} = 1;
  $opt->{pretty}   = 'medium';

  my $raw = defined $opt->{raw} && $opt->{raw};

  my @out = $self->RUN(log => $opt, @_);

  my @logs;
  while (my $line = shift @out) {
    die "unhandled: $line" unless $line =~ /^commit (\S+)/;

    my $current = Git::Wrapper::Log->new($1);

    $line = shift @out; # next line;

    while ($line =~ /^(\S+):\s+(.+)$/) {
      $current->attr->{lc $1} = $2;
      $line = shift @out; # next line;
    }

    die "no blank line separating head from message" if $line;

    my ( $initial_indent ) = $out[0] =~ /^(\s*)/ if @out;

    my $message = '';
    while (
      @out
      and $out[0] !~ /^commit (\S+)/
      and length($line = shift @out)
    ) {
      $line =~ s/^$initial_indent//; # strip just the indenting added by git
      $message .= "$line\n";
    }

    $current->message($message);

    if ($raw) {
      my @modifications;

      while(@out and $out[0] =~ m/^\:(\d{6}) (\d{6}) (\w{7})\.\.\. (\w{7})\.\.\. (\w{1})\t(.*)$/) {
        push @modifications, Git::Wrapper::File::RawModification->new($6,$5,$1,$2,$3,$4);
        shift @out;
      }
      $current->modifications(@modifications) if @modifications;
    }

    push @logs, $current;
  }

  return @logs;
}

sub supports_hash_object_filters {
  my $self = shift;

  # The '--no-filters' option to 'git-hash-object' was added in version 1.6.1
  return 0 if ( versioncmp( $self->version , '1.6.1' ) eq -1 );
  return 1;
}

sub supports_log_raw_dates {
  my $self = shift;

  # The '--date=raw' option to 'git log' was added in version 1.6.2
  return 0 if ( versioncmp( $self->version , '1.6.2' ) eq -1 );
  return 1;
}

sub supports_status_porcelain {
  my $self = shift;

  # The '--porcelain' option to git status was added in version 1.7.0
  return 0 if ( versioncmp( $self->version , '1.7' ) eq -1 );
  return 1;
}

my %STATUS_CONFLICTS = map { $_ => 1 } qw<DD AU UD UA DU AA UU>;

sub status {
  my $self = shift;

  return $self->RUN('status' , @_ )
    unless $self->supports_status_porcelain;

  my $opt  = ref $_[0] eq 'HASH' ? shift : {};
  $opt->{$_} = 1 for qw<porcelain>;

  my @out = $self->RUN(status => $opt, @_);

  my $statuses = Git::Wrapper::Statuses->new;

  return $statuses if !@out;

  for (@out) {
    my ($x, $y, $from, $to) = $_ =~ /\A(.)(.) (.*?)(?: -> (.*))?\z/;

    if ($STATUS_CONFLICTS{"$x$y"}) {
      $statuses->add('conflict', "$x$y", $from, $to);
    }
    elsif ($x eq '?' && $y eq '?') {
      $statuses->add('unknown', '?', $from, $to);
    }
    else {
      $statuses->add('changed', $y, $from, $to)
        if $y ne ' ';
      $statuses->add('indexed', $x, $from, $to)
        if $x ne ' ';
    }
  }
  return $statuses;
}

__END__

=head1 SYNOPSIS

  my $git = Git::Wrapper->new('/var/foo');

  $git->commit(...)
  print $_->message for $git->log;

=head1 DESCRIPTION

Git::Wrapper provides an API for git(7) that uses Perl data structures for
argument passing, instead of CLI-style C<--options> as L<Git> does.

=head1 METHODS

Except as documented, every git subcommand is available as a method on a
Git::Wrapper object.  Replace any hyphens in the git command with underscores.

The first argument should be a hashref containing options and their values.
Boolean options are either true (included) or false (excluded).  The remaining
arguments are passed as ordinary command arguments.

  $git->commit({ all => 1, message => "stuff" });

  $git->checkout("mybranch");

I<N.b.> Because of the way arguments are parsed, should you need to pass an
explicit '0' value to an option (for example, to have the same effect as
C<--abrrev=0> on the command line), you should pass it with a leading space, like so:

  $git->describe({ abbrev => ' 0' };

To pass content via STDIN, use the -STDIN option:

  $git->hash_object({ stdin => 1, -STDIN => 'content to hash' });

Output is available as an array of lines, each chomped.

  @sha1s_and_titles = $git->rev_list({ all => 1, pretty => 'oneline' });

If a git command exits nonzero, a C<Git::Wrapper::Exception> object will be
thrown.  It has three useful methods:

=over

=item * error

error message

=item * output

normal output, as a single string

=item * status

the exit status

=back

The exception stringifies to the error message.

=head2 new

  my $git = Git::Wrapper->new($dir);

=head2 dir

  print $git->dir; # /var/foo

=head2 version

  my $version = $git->version; # 1.6.1.4.8.15.16.23.42

=head2 log

  my @logs = $git->log;

Instead of giving back an arrayref of lines, the C<log> method returns a list
of C<Git::Wrapper::Log> objects.  They have four methods:

=over

=item * id

=item * author

=item * date

=item * message

=back

=head2 has_git_in_path

This method returns a true or false value indicating if there is a 'git'
binary in the current $PATH.

=head2 supports_status_porcelain

=head2 supports_log_raw_dates

=head2 supports_hash_object_filters

These methods return a true or false value (1 or 0) indicating whether the git
binary being used has support for these options. (The '--porcelain' option on
'git status', the '--date=raw' option on 'git log', and the '--no-filters'
option on 'git hash-object' respectively.)

These are primarily for use in this distribution's test suite, but may also be
useful when writing code using Git::Wrapper that might be run with different
versions of the underlying git binary.

=head2 status

When running with an underlying git binary that returns false for the
L</supports_status_porcelain> method, this method will act like any other
wrapped command: it will return output as an array of chomped lines.

When running with an underlying git binary that returns true for the
L</supports_status_porcelain> method, this method instead returns an
instance of Git::Wrapper::Statuses:

  my $statuses = $git->status;

Git::Wrapper:Statuses has two public methods. First, C<is_dirty>:

  my $dirty_flag = $statuses->is_dirty;

which returns a true/false value depending on whether the repository has any
uncommitted changes.

Second, C<get>:

  my @status = $statuses->get($group)

which returns an array of Git::Wrapper::Status objects, one per file changed.

There are four status groups, each of which may contain zero or more changes.

=over

=item * indexed : Changed & added to the index (aka, will be committed)

=item * changed : Changed but not in the index (aka, won't be committed)

=item * unknown : Untracked files

=item * conflict : Merge conflicts

=back

Note that a single file can occur in more than one group.  Eg, a modified file
that has been added to the index will appear in the 'indexed' list.  If it is
subsequently further modified it will additionally appear in the 'changed'
group.

A Git::Wrapper::Status object has three methods you can call:

  my $from = $status->from;

The file path of the changed file, relative to the repo root.  For renames,
this is the original path.

  my $to = $status->to;

Renames returns the new path/name for the path.  In all other cases returns
an empty string.

  my $mode = $status->mode;

Indicates what has changed about the file.

Within each group (except 'conflict') a file can be in one of a number of
modes, although some modes only occur in some groups (eg, 'added' never appears
in the 'unknown' group).

=over

=item * modified

=item * added

=item * deleted

=item * renamed

=item * copied

=item * conflict

=back

All files in the 'unknown' group will have a mode of 'unknown' (which is
redundant but at least consistent).

The 'conflict' group instead has the following modes.

=over

=item * 'both deleted' : deleted on both branches

=item * 'both added'   : added on both branches

=item * 'both modified' : modified on both branches

=item * 'added by us'  : added only on our branch

=item * 'deleted by us' : deleted only on our branch

=item * 'added by them' : added on the branch we are merging in

=item * 'deleted by them' : deleted on the branch we are merging in

=back

See git-status man page for more details.

=head3 Example

    my $git = Git::Wrapper->new('/path/to/git/repo');
    my $statuses = $git->status;
    for my $type (qw<indexed changed unknown conflict>) {
        my @states = $statuses->get($type)
            or next;
        print "Files in state $type\n";
        for (@states) {
            print '  ', $_->mode, ' ', $_->from;
            print ' renamed to ', $_->to
                if $_->mode eq 'renamed';
            print "\n";
        }
    }

=head2 RUN

This method bypasses the output rearranging performed by some of the wrapped
methods described above (i.e., C<log>, C<status>, etc.). This can be useful
in various situations, such as when you want to produce a particular log
output format that isn't compatible with the way C<Git::Wrapper> constructs
C<Git::Wrapper::Log>, or when you want raw C<git status> output that isn't
parsed into a <Git::Wrapper::Status> object.

This method should be called with an initial string argument of the C<git>
subcommand you want to run, followed by a hashref containing options and their
values, and then a list of any other arguments.

=head3 Example

    my $git = Git::Wrapper->new( '/path/to/git/repo' );

    # the 'log' method returns Git::Wrapper::Log objects
    my @log_objects = $git->log();

    # while 'RUN('log')' returns an array of chomped lines
    my @log_lines = $git->RUN('log');

=head2 ERR

After a command has been run, this method will return anything that was sent
to C<STDERR>, in the form of an array of chomped lines. This information will
be cleared as soon as a new command is executed. This method should B<*NOT*>
be used as a success/failure check, as C<git> will sometimes produce output on
STDERR when a command is successful.

=head2 OUT

After a command has been run, this method will return anything that was sent
to C<STDOUT>, in the form of an array of chomped lines. It is identical to
what is returned from the method call that runs the command, and is provided
simply for symmetry with the C<ERR> method. This method should B<*NOT*> be
used as a success/failure check, as C<git> will frequently not have any output
with a successful command.

=head1 COMPATIBILITY

On Win32 Git::Wrapper is incompatible with msysGit installations earlier than
Git-1.7.1-preview20100612 due to a bug involving the return value of a git
command in cmd/git.cmd.  If you use the msysGit version distributed with
GitExtensions or an earlier version of msysGit, tests will fail during
installation of this module.  You can get the latest version of msysGit on the
Google Code project page: L<http://code.google.com/p/msysgit/downloads>

=head1 ENVIRONMENT VARIABLES

Git::Wrapper normally uses the first 'git' binary in your path, but if the
GIT_WRAPPER_GIT environment variable is set, that value will be used instead.

=head1 SEE ALSO

L<VCI::VCS::Git> is the git implementation for L<VCI>, a generic interface to
version-controle systems.

L<Other Perl Git Wrappers|https://metacpan.org/module/Git::Repository#OTHER-PERL-GIT-WRAPPERS>
is a list of other Git interfaces in Perl. If L<Git::Wrapper> doesn't scratch
your itch, possibly one of the modules listed there will.

Git itself is at L<http://git.or.cz>.

=head1 REPORTING BUGS & OTHER WAYS TO CONTRIBUTE

The code for this module is maintained on GitHub, at
L<https://github.com/genehack/Git-Wrapper>. If you have a patch, feel free to
fork the repository and submit a pull request. If you find a bug, please open
an issue on the project at GitHub. (We also watch the L<http://rt.cpan.org>
queue for Git::Wrapper, so feel free to use that bug reporting system if you
prefer)

=cut
