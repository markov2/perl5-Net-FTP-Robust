# This code is part of distribution Net-FTP-Robust.  Meta-POD processed
# with OODoc into POD and HTML manual-pages.  See README.md
# Copyright Mark Overmeer.  Licensed under the same terms as Perl itself.

package Net::FTP::Robust;

use warnings;
use strict;

use Log::Report 'net-ftp-robust', syntax => 'SHORT';
use Net::FTP;
use Time::HiRes qw/gettimeofday tv_interval/;

use Data::Dumper;

sub size_short($);
use constant
  { GB => 1024 * 1024 * 1024
  , MB => 1024 * 1024
  , kB => 1024
  };

=chapter NAME

Net::FTP::Robust - download files over FTP

=chapter SYNOPSIS

 my $ftp = Net::FTP::Robust->new
  ( Host    => $host
  , Port    => $port
  , Passive => 1
  );

 # when needed, many attempts will be made to retrieve all
 $ftp->get($remote_dir, $local_dir);
 $ftp->get($remote_dir);

 # to get client-side errors as well:
 use Log::Report;       # get 'try()'
 try { $ftp->get(...) };
 if($@) {...}

 # make the process more verbose, start with
 Log::Report mode => 'VERBOSE';
 Log::Report mode => 'DEBUG';

 # to catch all reports: errors, warnings, debugs etc
 try { $ftp->get(...) } mode => 'DEBUG';
 push @trace, $@->exceptions; # simply prints all
 $@->reportFatal;             # re-cast real errors

=chapter DESCRIPTION

This module is specialized in (on the moment only) downloading large
data-sets (gigabytes) autonomously. It uses M<Net::FTP>, and adds various
algorithms to work around various common problems.  In general, local
errors are fatal and server or network errors are recovered.

See L</DETAILS> far down on this page for more explanations and
limitations.

=chapter METHODS

=section Constructors

=c_method new OPTIONS

Use to connect to one ftp-server.
All B<OPTIONS which start with capitals> are passed to M<Net::FTP>
method C<new()>.

=option  host     HOSTNAME
=default host     <undef>
Alternative for the C<Host> parameter for M<Net::FTP::new()>.

=option  user     STRING
=default user     'anonymous'

=option  password STRING
=default password '-anonymous@'

=option  login_attempts INTEGER
=default login_attempts 10
How often will the connection be rebuilt. Between each attempt,
we wait C<login_delay> seconds.  When '0' is specified, it will
continue forever: you can solve problems discovered in the logs.

=option  login_delay INTEGER
=default login_delay 60
How much time to wait between retries which require to login again,
in seconds.

=option  skip_names CODE
=default skip_names <skip hidden files>
Do not attempt directories or files which contain certain patterns.
When the CODE returns 1, then the element will be ignored.  Typically,
the CODE will apply some regular expressions.

The CODE reference will get three arguments: the ftp object (M<Net::FTP>)
with established connection, the full remote path of the entry, and the
basename of the entry.
=cut

sub new() { my $class = shift; (bless {}, $class)->init( {@_} ) }

sub init($)
{   my ($self, $args) = @_;

    # delete all my own options from the %$args
    $self->{login_attempts}
       = defined $args->{login_attempts} ? delete $args->{login_attempts} : 10;

    # probably, some people will attempt lowercased 'host'
    $args->{Host}         ||= delete $args->{host};

    $self->{login_user}     = delete $args->{user}        || 'anonymous';
    $self->{login_password} = delete $args->{password}    || '-anonymous@';
    $self->{login_delay}    = delete $args->{login_delay} || 60;

    $self->{skip_names}     = delete $args->{skip_names}
       || sub { $_[2] =~ m/^\./ };  # UNIX hidden files

    $self->{ftp_opts}       = $args;
    $self;
}

=section Download

=method get FROM, [TO]
The FROM directory or file on the remote server is copied TO a local
directory (defaults to '.')

=cut

sub _connect($)
{   my ($self, $opts) = @_;
    my $ftp  = Net::FTP->new(%$opts);
    my $err  = defined $ftp ? undef : $@;
    ($ftp, $err);
}

sub get($$)
{   my ($self, $from, $to) = @_;

    $to = File::Spec->curdir
        unless defined $to && length $to;
    $from =~ s,^/?,/,g;  # ensure leading /

    my $retries = $self->{login_attempts} || 1_000_000;
    my $success = 0;

  ATTEMPT:   # see continue block at end
    foreach my $attempt (1..$retries)
    {   info __x"connection attempt {nr}{max}"
          , nr => $attempt, max => ($retries ? " of $retries" : '')
            if $attempt != 1;

        my ($ftp, $err) = $self->_connect($self->{ftp_opts});
        unless($ftp)
        {   notice __x"cannot establish contact: {err}", err => $err;
            next ATTEMPT;
        }

        unless( $ftp->login($self->{login_user}, $self->{login_password}))
        {   notice __x"login failed: {msg}", msg => ($ftp->message || $!);
            next ATTEMPT;
        }

        $ftp->binary;
        my ($dir, $base) = $from =~ m!^(?:(.*)/)?([^/]*)!;
        $dir ||= '/';
        unless($ftp->cwd($dir))
        {   notice __x"directory {dir} does not exist: {msg}"
              , dir => $dir, msg => ($ftp->message || $!);
            next ATTEMPT;
        }

        my $stats   = $self->{stats}
                    = { files => 0, new_files => 0, downloaded => 0 };
        my $start   = [ gettimeofday ];
        $success    = $self->_recurse($ftp, $dir, $base, $to);
        my $elapsed = tv_interval $start;

        $success
            or notice __x"attempt {nr} unsuccessful", nr => $attempt;

        info __x"Got {new} new files, {size} in {secs}s avg {speed}/s"
          , new   => $stats->{new_files}
          , total => $stats->{files}
          , size  => size_short($stats->{downloaded})
          , secs  => int($elapsed)
          , speed => size_short($stats->{downloaded} / $elapsed);

        $ftp->close;

        last if $success;
    }
    continue
    {   sleep $self->{login_delay};
    }

    $success;
}

sub _recurse($$$$)
{   my ($self, $ftp, $dir, $entry, $to) = @_;

    my $full = $dir . $entry;
    if($self->{skip_names}->($ftp, $full, $entry))
    {   trace "skipping $full";
        return 1;
    }

    if(!length $entry)
    {   -d $to || mkdir $to
            or fault __x"cannot create directory {dir}", dir => $to;

        return $self->_get_directory($ftp, $dir, $to);
    }
    elsif($ftp->cwd($entry))
    {   # Entering directory
        $to = File::Spec->catdir($to, $entry);
        
        -d $to || mkdir $to
            or fault __x"cannot create directory {dir}", dir => $to;

        $full .= '/' if $full ne '/';
        my $success = $self->_get_directory($ftp, $full, $to);
        if($success)
        {   $success = $ftp->cdup
                or notice __x"cannot go cdup to {dir}: {msg}"
                     , dir => $dir, msg => ($ftp->message || $!);
        }
        return $success;
    }

    $self->_get_file($ftp, $dir, $entry, $to);
}

sub _ls($) { $_[1]->ls }

sub _get_directory($$$)
{   my ($self, $ftp, $where, $to) = @_;
    my @entries = $self->_ls($ftp);

    trace "directory $where has ".@entries. " entries";

    foreach my $entry (@entries)
    {   my $success = $self->_recurse($ftp, $where, $entry, $to);
        $success or return 0;
    }

    1;
}

# Different in Net::FTPSSL
sub _modif_time($$)
{   my ($self, $ftp, $fn) = @_;
    $ftp->mdtm($fn) || 0;
}
    
sub _can_restart($$$$)
{   my ($self, $ftp, $name, $temp, $expected_size) = @_;
    my $got_size = -s $temp || 0;
    $got_size or return 0;

    # download did not complete last time
    my $to_download   = $expected_size - $got_size;
    info "continue file $name, got " . size_short($got_size)
       . " from " . size_short($expected_size)
       . ", needs " . size_short($to_download);

    $ftp->restart($got_size);
    $got_size;
}

sub _get_file($$$$)
{   my ($self, $ftp, $dir, $base, $to) = @_;

    my $remote_name = $dir . $base;
    my $local_name  = "$to/$base";
    my $local_temp  = "$to/.$base";

    my $remote_mtime = $self->_modif_time($ftp, $base);
    my $stats        = $self->{stats};
    $stats->{files}++;

    if(-e $local_name)
    {   # file already downloaded, still valid?
        if(! -f $local_name)
        {   # not downloadable
            notice __x"download file {fn}, but already exists as non-file"
              , fn => $local_name;
            return 1;
        }

        my $local_mtime = (stat $to)[9];
        if($remote_mtime && $local_mtime >= $remote_mtime)
        {   trace "file $remote_name already downloaded";
            return 1;
        }

        trace "local file $local_name is outdated";
        # continue as if the file does not exist
    }

    my $expected_size = $ftp->size($base);
    my $got_size
       = $self->_can_restart($ftp, $local_name, $local_temp, $expected_size)
          or trace "get " . size_short($expected_size). " for $local_name";
 
    my $success;
    if(defined $expected_size && $expected_size==$got_size)
    {   # download succesful, but mv or close was not
        $success = 1;
        if($expected_size==0)
        {   open OUT, '>', $local_temp
                or fault __x"cannot create empty {file}", file => $local_temp;
            close OUT;
        }
    }
    else
    {   my $start   = [ gettimeofday ];
        $success    = $ftp->get($base, $local_temp);
        my $elapsed = tv_interval $start;

        my $downloaded = (-s $local_temp || 0) - $got_size;

        if($downloaded)
        {   info __x"{amount} in {secs}s is {speed}/s: {fn}"
             , amount => size_short($downloaded)
             , secs => sprintf("%7.3f", $elapsed)
             , speed  => size_short($downloaded/$elapsed), fn => $base;
            $stats->{downloaded} += $downloaded;
        }
        else
        {   notice __x"failed to get any bytes from {fn}: {err}"
              , fn => $local_name, err => $ftp->message;
            $success = 0;
        }
    }

    if($success)
    {   # accept the downloaded file
        utime $remote_mtime, $remote_mtime, $local_temp; # only root
        unlink $local_name;                              # might exist
        unless(rename $local_temp, $local_name)
        {   fault __x"cannot rename {old} to {new}"
              , old => $local_temp, new => $local_name;
        }
        $stats->{new_files}++;
    }

    $success;
}

sub size_short($)
{   my $size = shift || 0;
    my $name = ' B';
    ($size, $name) = ($size/1024, 'kB') if $size > 1000;
    ($size, $name) = ($size/1024, 'MB') if $size > 1000;
    ($size, $name) = ($size/1024, 'GB') if $size > 1000;

    my $format = $size >= 100 ? "%4.0f%s" : "%4.1f%s";
    sprintf $format, $size, $name;
}

=chapter DETAILS

=section Comparison

M<Net::FTP> implements the FTP protocol.
Various modules on CPAN asbtract the transport protocol further,
for instance M<Net::FTP::Recurse>.  Each module has its own focus.
C<Net::FTP::Robust> is specialized in retries and logging, to retrieve
data which takes hours to download, sometimes over quite instable
connections.  It uses M<Log::Report> which can connect to various logging
frameworks for its messages.

=section Limitations

The M<get()> will collect directories recursively or single files.

When a new M<get()> is ran with the same destination directory, then
the download will continue where it left-of.  Files which were only
partially downloaded will get downloaded only for the missing part.

Files will not get deleted, not on the server and not on the client.
Symbolic links on the server are invisible on the local copy.

When downloading, the name of the directory and file will temporarily be
mangled: only when the download is completed, the real name will show up.
For UNIX, the names will temporarily start with a dot, to be hidden from
the standard C<ls(1)> output.

When you have the permission from your OS, the modification time
will get copied from the source as well.

=cut

1;
