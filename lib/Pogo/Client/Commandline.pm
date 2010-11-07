package Pogo::Client::Commandline;

# Copyright (c) 2010, Yahoo! Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

use Data::Dumper;

use common::sense;

use Getopt::Long qw(:config bundling no_ignore_case pass_through);
use Crypt::OpenSSL::RSA;
use Crypt::OpenSSL::X509;
use JSON qw(to_json);
use Log::Log4perl qw(:easy);
use Log::Log4perl::Level;
use MIME::Base64 qw(encode_base64);
use Pod::Find qw(pod_where);
use Pod::Usage qw(pod2usage);
use Sys::Hostname qw(hostname);
use Time::HiRes qw(gettimeofday tv_interval);
use YAML::XS qw(LoadFile);

use Pogo::Common;
use Pogo::Client;
use Pogo::Client::AuthCheck qw(get_password check_password);

use constant POGO_GLOBAL_CONF     => $Pogo::Common::CONFIGDIR . '/client.conf';
use constant POGO_USER_CONF       => $ENV{HOME} . '/.pogoconf';
use constant POGO_WORKER_CERT     => $Pogo::Common::WORKER_CERT;
use constant POGO_PASSPHRASE_FILE => 'bar';

my %LOG_SUBST = (
  'jobstate' => 'job',
  'hoststate' => 'host',
);


sub run_from_commandline
{
  my $class = shift;

  my $self = {
    epoch      => [gettimeofday],
    invoked_as => quote_array( " ", $0, @ARGV ),
    userid     => scalar getpwuid($<),
  };

  bless $self, $class;

  my $cmd = $self->process_options
    or $self->cmd_usage;

  $self->{api} = delete $self->{opts}->{api};

  my $method = 'cmd_' . $cmd;
  if ( !$self->can($method) )
  {
    LOGDIE "no such command: $cmd\n";
  }

  return $self->$method;
}

#{{{ cmd_run

sub cmd_run
{
  my $self = shift;
  my $opts = {
    retry       => 0,
    invoked_as  => $self->{invoked_as},
    client      => $Pogo::Client::VERSION,
    user        => $self->{userid},
    requesthost => hostname || '',
  };
  GetOptions(
    my $cmdline_opts = {}, 'cookbook|C=s',
    'hostfile|H=s',              'target|host|h=s@',
    'job_timeout|job-timeout=i', 'dryrun|n',
    'recipe|R=s',                'retry|r=i',
    'timeout|t=i',               'prehooks!',
    'posthooks!',                'hooks!',
    'passfile|P=s',              'unconstrained',
    'concurrent|cc=s',           'file|f=s',
  );

  # --hooks will affect the default setting of both prehooks and posthooks.  If
  # the more specific option also appears, it will override the setting of
  # --hooks.
  if ( defined $cmdline_opts->{hooks} )
  {
    $opts->{prehooks} = $opts->{posthooks} = $cmdline_opts->{hooks};
  }

  # merge global options over default options
  $opts = merge_hash( $opts, $self->{opts} );

  # This is kind of weird; the commandline opts should override the recipe,
  # so we can't merge $cmdline_opts yet, but the cookbook and recipe are
  # commandline arguments themselves, so we need to check both $cmdline_opts and $opts.
  if ( $cmdline_opts->{recipe} )
  {
    my $cookbook = $self->load_cookbook( $cmdline_opts->{cookbook} || $opts->{cookbook} );
    if ( defined $cookbook )
    {
      my $recipe = $self->load_recipe( $cmdline_opts->{recipe}, $cookbook );
      $opts = merge_hash( $opts, $recipe );
    }
  }

  # merge per-cmd options over global options and cookbook options
  $opts = merge_hash( $opts, $cmdline_opts );
  if ( @ARGV > 0 )
  {
    $opts->{command} = "@ARGV";
  }
  elsif ( $opts->{cmd} )
  {
    $opts->{command} = delete $opts->{cmd};
  }

  # run an anonymous executable?
  if ( defined $opts->{file} )
  {
    LOGDIE "file \"" . $opts->{file} . "\" does not exist\n" unless -e $opts->{file};
    LOGDIE "unable to read \"" . $opts->{file} . "\"\n"      unless -r $opts->{file};

    $opts->{exe_name} = ( split( /\//, $opts->{file} ) )[-1];
    $opts->{exe_data} = encode_base64( read_file( $opts->{file} ) );
    $opts->{command}  = "Attached file: " . $opts->{exe_name};
  }

  LOGDIE "run needs a command\n"
    unless defined $opts->{command};

  my @targets;

  if ( exists $opts->{target} )
  {
    push @targets, @{ delete $opts->{target} };
  }

  if ( $opts->{hostfile} )
  {
    foreach my $hostfile ( @{ $opts->{hostfile} } )
    {
      if ( -r $hostfile )
      {
        open( my $fh, '<', $hostfile )
          or LOGDIE "Couldn't open file: $!";

        while ( my $host = <$fh> )
        {
          next unless $host;
          next if $host =~ m/^\s*#/;
          chomp($host);
          push @targets, $host;
        }
        close($fh);
      }
      else
      {
        LOGDIE "couldn't read '$hostfile'";
      }
    }
  }

  if ( @targets == 0 )
  {
    LOGDIE "run needs hosts!";
  }

  $opts->{target} = \@targets;

  # package passphrases
  my $passphrase;
  if ( $opts->{passfile} )
  {
    $passphrase = load_passphrases( $opts->{passfile} );

    if ( !$passphrase )
    {
      ERROR "Can't load passphrases from $opts->{passfile}: $!";
    }
  }
  else
  {
    $passphrase = load_passphrases(POGO_PASSPHRASE_FILE);
  }

  # --unconstrained means we're 100% in parallel
  if ( delete $opts->{unconstrained} )
  {
    LOGDIE "--unconstrained and --concurrent are mutually exclusive"
      if exists $opts->{concurrent};
    $opts->{concurrent} = 0;
  }

  # check the value of concurrent
  if ( exists $opts->{concurrent} )
  {
    LOGDIE "--concurrent value must be an integer or a percentage"
      unless $opts->{concurrent} =~ m/^\d+%?$/;
  }

  if ( $opts->{dryrun} )
  {
    my $key;
    my $value;
    format DRYRUN =
^>>>>>>>>>>>>>>>>>> => ^*
$key,                  $value
.

    format_name STDOUT "DRYRUN";

    foreach $key ( sort keys %$opts )
    {
      $value = $opts->{$key};
      if ( ref $value eq 'ARRAY' )
      {
        $value = join ',', @$value;
      }
      $value = join( '; ', split /\n/, $value );
      write STDOUT;
    }

    return 0;
  }

  my $password = get_password();

  # use CLI::Auth to validate
  # note that this is just testing against the local password in case you happen
  # to use the same one everywhere - to avoid spewing the wrong password to
  # thousands of hosts, this is not a real auth check
  if ( $opts->{check_password} )
  {
    if ( !check_password( $self->{userid}, $password ) )
    {
      LOGDIE
        "Local password check failed, bailing\nset 'check_password: 0' in your .pogoconf to disable\n";
    }
  }

  # bring the crypto
  Crypt::OpenSSL::RSA->import_random_seed();
  my $x509    = Crypt::OpenSSL::X509->new_from_file(POGO_WORKER_CERT);
  my $rsa_pub = Crypt::OpenSSL::RSA->new_public_key( $x509->pubkey() );

  # encrypt the password
  my $cryptpw = encode_base64( $rsa_pub->encrypt($password) );

  $opts->{user}     = $self->{userid};
  $opts->{run_as}   = $self->{userid};
  $opts->{password} = $cryptpw;

  $opts->{pkg_passwords} =
    { map { $_ => encode_base64( $rsa_pub->encrypt( $passphrase->{$_} ) ) } keys %$passphrase };

  my $resp = $self->_client->run(%$opts);

  if ( !$resp->is_success )
  {
    LOGDIE "Failed to start job: " . $resp->status_msg;
  }

  my $jobid = $resp->record;

  $SIG{INT}     = sub { $self->pogo_client()->jobhalt($jobid) if $jobid; exit 1; };
  $SIG{__DIE__} = sub { $self->pogo_client()->jobhalt($jobid) if $jobid; die @_; };

  print "$jobid; " . $self->{ui} . $jobid . "\n";

  # $self->wait_job($jobid);
  return 0;
}

#}}} cmd_run
#{{{ cmd_ping

sub cmd_ping
{
  my $self = shift;
  my $res;
  my $resp = $self->_client()->ping('pong');
  my $elapsed = tv_interval( $self->{epoch}, [gettimeofday] );
  if ( !$resp->is_success )
  {
    printf "ERROR %s: %s\n", $self->{api}, $@;
    return 1;
  }

  my @foo  = $resp->records;
  my $pong = shift @foo;

  if ( !$pong )
  {
    printf "ERROR %s: no pong!\n", $self->{api};
    return 1;
  }
  if ( $pong ne 'pong' )
  {
    printf "ERROR %s: %s\n", $self->{api}, $pong;
    return 1;
  }

  printf "OK %s %0dms\n", $self->{api}, $elapsed * 1000;
  return 0;
}

#}}}
#{{{ cmd_jobs

sub cmd_jobs
{
  my $self = shift;
  my $opts = {
    user  => $self->{userid},
    limit => 50,
  };
  GetOptions( $opts, 'user|U=s', 'all', 'limit|L=i' );
  delete $opts->{user} if $opts->{all};
  delete $opts->{all}  if $opts->{all};

  DEBUG "cmd_jobs: " . to_json($opts);

  my $resp = $self->_client()->listjobs(%$opts);
  if ( !$resp->is_success )
  {
    LOGDIE "Unable to list jobs: " . $resp->status_msg;
  }

  my @matches;
  my @jobs  = $resp->records;
  my $count = 0;

JOBS: foreach my $job ( sort { $b->{jobid} cmp $a->{jobid} } @jobs )
  {
    push @matches, $job;
    $count++;
  }

  format JOB_TOP =
Job ID      User     Command
.

  my $job;
  format JOB =
@<<<<<<<<<< @<<<<<<< @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
$job->{jobid}, $job->{user}, '\''. $job->{command}. '\'',
.

  foreach $job ( sort { $a->{jobid} cmp $b->{jobid} } @matches )
  {

    if ( !defined $job->{jobid}
      || !defined $job->{user}
      || !defined $job->{command} )
    {
      DEBUG "skipping invalid job: " . $job->{'jobid'} || 'NULL';
      next;
    }

    format_name STDOUT "JOB";
    format_top_name STDOUT "JOB_TOP";
    write STDOUT;
  }
}

#}}}
#{{{ cmd_status

sub cmd_status
{
  my $self = shift;
  my $opts = {};

  # fetchez le options
  GetOptions( $opts, 'target|h=s', 'status|s=s', 'verbose|v' );

  # process the jobid
  my $jobid = shift @ARGV;
  if ( defined $jobid )
  {
    $jobid = $self->to_jobid($jobid);
    if ( !defined $jobid )
    {
      LOGDIE "No jobs found";
    }
    DEBUG "Using jobid '$jobid'";
  }
  else
  {
    LOGDIE "no jobid specified";
  }

  # expand the range if needed
  my $target;
  if ( defined $opts->{target} )
  {
    $target = $self->expand_expression( $opts->{target} );
  }

  # fetch the job info
  my $resp = $self->_client()->jobinfo( $jobid, %$opts );
  if ( !$resp->is_success )
  {
    LOGDIE "Unable to fetch jobinfo: " . $resp->status_msg;
  }

  # output job info
  my $info = $resp->record;
  my $disp = {
    'job id'     => $jobid,
    'user'       => $info->{user},
    'command'    => $info->{command},
    'invoked as' => $info->{invoked_as},
  };

  if ( $opts->{verbose} ) { $disp = $info; }

  my $len = 5;
  map { $len = length($_) if $len < length($_) } keys %{$disp};

  my $pat = " %${len}s: %s\n";

  foreach my $key ( keys %{$disp} )
  {
    printf "$pat", $key, $disp->{$key};
  }

  # fetch the status
  $resp = $self->_client()->jobstatus($jobid);
  if ( !$resp->is_success )
  {
    LOGDIE "Unable to fetch jobstatus: " . $resp->status_msg;
  }

  # output status
  my @rec    = $resp->records;
  my $status = shift @rec;
  printf "$pat", "job status", $status;
  while ( my $rec = shift @rec )
  {
    my ( $host, $status, $exit ) = @$rec;
    if ( !defined $target || $target->contains($host) )
    {
      if ( !exists $opts->{status} || $opts->{status} eq $status )
      {
        print "  $host => $status\n";
      }
    }
  }

  return 0;
}

#}}}
#{{{ cmd_log

sub cmd_log
{
  my $self = shift;
  my $opts = { verbose => 0 };

  GetOptions( $opts, 'tail|f', 'verbose|v' )
    or $self->usage;

  my $jobid = shift @ARGV;
  $opts = merge_hash( $self->{opts}, $opts );

  if ( defined $jobid )
  {
    $jobid = $self->to_jobid($jobid);
    if (!defined $jobid)
    {
      print "No jobs found\n";
      return 1;
    }
    DEBUG "Using jobid '$jobid'";
  }
  unless ($jobid)
  {
    LOGDIE "no jobid specified\n";
  }

  my $hosts;
  my $target = shift @ARGV;

  if (defined $target )
  {
    $hosts = $self->expand_expression($target);
  }

  my $idx = 0;
  my $limit = 100;
  my $finished = 0;
  my $resp;

  do {
    $resp = $self->_client->joblog( $jobid, $idx, $limit );
    if (!$resp->is_success)
    {
      ERROR "%s: %s\n", $self->{api}, $resp->status_msg;
      return -1;
    }

    foreach my $record ( sort { $a->[0] <=> $b->[0] } $resp->records )
    {
      $idx = ( shift @$record ) + 1;
      display_log_event( $jobid, $record, $opts->{verbose}, $hosts );
      if ($record->[1] eq 'jobstate' )
      {
        my $newstate = $record->[2]->{state};
        $finished = 1 if ( $newstate eq 'finished' or $newstate eq 'halted' );
      }
    }
  } while (scalar $resp->records == $limit );

  if ($opts->{tail})
  {
    while (!$finished)
    {
      $resp = $self->_client->joblog( $jobid, $idx, $limit );
      if (!$resp->is_success)
      {
        ERROR "ERROR: %s: %s\n", $self->api, $resp->status_msg;
      }

      my $laststate;
      my $lastthing;

      foreach my $record ( sort { $a->[0] <=> $b->[0] } $resp->records )
      {
        $idx = ( shift @$record ) + 1;
        display_log_event( $jobid, $record, $opts->{verbose}, $hosts );
        if ( $record->[1] eq 'jobstate' )
        {
          my $newstate = $record->[2]->{state};
          $finished = 1 if ( $newstate eq 'finished' or $newstate eq 'halted' );
        }
      }

      sleep 0.6 unless scalar $resp->records == $limit;
    }
  }

  return 0;
}

sub display_log_event
{
  my ($jobid, $event, $verbose, $hosts) = @_;
  my ($ts, $type, $details, $summary) = @$event;

  $ts = to_ts($ts);

  # cosmetic crap
  if (defined $LOG_SUBST{$type})
  {
    $type = $LOG_SUBST{$type};
  }

  my $ok = 1;
  if (defined $hosts && $type eq 'host' && ref $details eq 'HASH' )
  {
    $ok = $hosts->has($details->{host});
  }

  if (ref $details eq 'HASH')
  {
    if ( defined $details->{host} )
    {
      $type = "$type/" . $details->{host};
    }
  }
  else
  {
    $type = $details;
  }

  my ( $keys, $values );
  format JOBLOG =
@<<<<<<<<<<<<<<<<<<<<<<< @* => @*
$ts,                     $type, $summary
.

  format JOBLOG_VERBOSE =
@<<<<<<<<<<<<<<<<<<<<<<< @* => @*
$ts,                     $type, $summary
                         ^* => ^*
~~                       $keys, $values
.

  if ($ok)
  {
    if ($verbose)
    {
      format_name STDOUT 'JOBLOG_VERBOSE';
      $keys = join "\n", keys %$details;
      $values = join "\n", values %$details;
      write;
    }
    else
    {
      format_name STDOUT 'JOBLOG';
      write;
    }
  }
}

#}}}
#{{{ options processing and usage

sub process_options
{
  my $self = shift;

  my $command;
  my $opts         = {};
  my $cmdline_opts = {};

  # first, process global options and see if we have an alt config file
  GetOptions( $cmdline_opts, 'help|?', 'api=s', 'configfile=s', 'debug', 'namespac|ns=s', );

  Log::Log4perl::get_logger->level($DEBUG)
    if $cmdline_opts->{debug};

  $self->cmd_usage
    if $cmdline_opts->{help};

  # our next @ARGV should be our command
  $command = shift @ARGV || return;
  if ( $command =~ m/^-/ )
  {
    ERROR "Unknown option: $command";
    return;
  }

  # load global config
  my $opts->{configfile} = $cmdline_opts->{configfile} || POGO_GLOBAL_CONF;

  my $globalconf = {};

  if ( -r $opts->{configfile} )
  {
    DEBUG "Loading configfile '" . $opts->{configfile} . "'";
    eval { $globalconf = LoadFile( $opts->{configfile} ); };
    if ($@)
    {
      ERROR "Could't load config '" . $opts->{configfile} . "': $@";
      return;
    }

    # opts start with configfile
    $opts = $globalconf;
  }
  else
  {
    WARN "Couldn't open config '" . $opts->{configfile} . "'";
  }

  # overwrite with user conf
  my $userconf = {};
  if ( -r POGO_USER_CONF )
  {
    DEBUG "Loading configfile '" . POGO_USER_CONF . "'";
    eval { $userconf = LoadFile(POGO_USER_CONF); };
    if ($@)
    {
      WARN "Couldn't load config '" . POGO_USER_CONF . "': $@";
    }
    if ($userconf)
    {
      $opts = merge_hash( $opts, $userconf );
      $opts->{configfile} = POGO_USER_CONF;
    }
  }

  # overwrite with commandline opts
  $self->{opts} = merge_hash( $opts, $cmdline_opts );

  return $command;
}

sub cmd_help
{
  return $_[0]->cmd_man;
}

sub cmd_man
{
  return pod2usage(
    -verbose => 2,
    -exitval => 0,
    -input   => pod_where( { -inc => 1, }, __PACKAGE__ ),
  );
}

sub cmd_usage
{
  my $self = shift;
  return pod2usage(
    -verbose  => 99,
    -exitval  => shift || 1,
    -input    => pod_where( { -inc => 1 }, __PACKAGE__ ),
    -sections => 'USAGE|MORE INFO',
  );
}

#}}} options processing and usage
#{{{ helper crap

# this is a bit of a mystery to me
sub quote_array
{
  my ( $sep, @array ) = @_;
  foreach my $elem (@array)
  {
    if ( $elem !~ m/^[a-z0-9+_\.\/-]+$/i )
    {
      $elem = "'$elem'";
    }
  }
  my $str .= join( $sep, @array );
  $str .= $sep;
  return $str;
}

sub merge_hash
{
  my ( $onto, $from ) = @_;

  while ( my ( $key, $value ) = each %$from )
  {
    if ( defined $onto->{$key} )
    {
      DEBUG sprintf "Overwriting key '%s' with '%s', was '%s'", $key, $value, $onto->{$key};
    }
    $onto->{$key} = $value;
  }

  return $onto;
}

sub _client
{
  my $self = shift;
  if ( !defined $self->{pogoclient} )
  {
    $self->{pogoclient} = Pogo::Client->new( $self->{api} );
    Log::Log4perl->get_logger("Pogo::Client")->level($DEBUG) if ( $self->{opts}->{debug} );
  }

  return $self->{pogoclient};
}

sub load_passphrases
{
  my $file = shift;
  if ( -r $file )
  {
    my $data = load_yaml($file)
      or ERROR "Couldn't load data from '$file': $!" and return;
    foreach my $pkg ( sort keys %$data )
    {
      DEBUG "Got passphrase for '$pkg'";
    }

    return $data;
  }
  else
  {
    INFO "Can't load data from '$file': $!";
    return;
  }

  return;
}

# we're just always going to have to do this server-side for now
sub expand_expression
{
  my ($self, @foo) = @_;

  my @hosts;
  foreach my $exp (@foo)
  {
    DEBUG "expanding $exp";

    my $resp;
    eval { $resp = $self->_client()->expand(\@foo); };
    if ($@ || !$resp->is_success)
    {
      LOGDIE "unable to expand '$exp': " . $@ || $resp->status_msg;
    }
    push( @hosts, @{ $resp->records } );
  }

  return Set::Scalar->new(@hosts);
}

sub to_jobid
{
  my ( $self, $jobid ) = @_;

  my $p = 'p';
  my $i;

  if ( $jobid eq 'last' )
  {
    $jobid = $self->get_last_jobid( $self->{userid} );
  }

  if ( $jobid =~ m/^([a-z]+)(\d+)$/ )
  {
    ( $p, $i ) = ( $1, $2 );
  }
  elsif ( $jobid =~ m/^(\d+)$/ )
  {
    $i = $1;
  }
  else
  {
    ERROR "Don't understand jobid '$jobid'";
    return;
  }

  my $new_jobid;
  if ( defined $i )
  {
    $new_jobid = sprintf "%s%010d", $p, $i;
    DEBUG "Translated jobid '$jobid' to '$new_jobid'";
  }
  else
  {
    INFO "No jobs found";
  }

  return $new_jobid;
}

#}}} helper crap

1;

=pod

=head1 NAME

  CLASSNAME - SHORT DESCRIPTION

=head1 SYNOPSIS

CODE GOES HERE

=head1 DESCRIPTION

LONG_DESCRIPTION

=head1 METHODS

B<methodexample>

=over 2

methoddescription

=back

=head1 SEE ALSO

L<Pogo::Dispatcher>

=head1 COPYRIGHT

Apache 2.0

=head1 AUTHORS

  Andrew Sloane <asloane@yahoo-inc.com>
  Michael Fischer <mfischer@yahoo-inc.com>
  Nicholas Harteau <nrh@yahoo-inc.com>
  Nick Purvis <nep@yahoo-inc.com>
  Robert Phan <rphan@yahoo-inc.com>

=cut

# vim:syn=perl:sw=2:ts=2:sts=2:et:fdm=marker
