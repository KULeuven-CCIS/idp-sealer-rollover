#!/usr/bin/env perl

#######################################################
# Roll over IdP sealer keys using a Idp Docker image. #
# https://github.com/nxadm/idp-sealer-rollover        #
#######################################################

use warnings;
use strict;
use feature 'say';
use File::Copy qw/copy move/;
use Getopt::Long;
use POSIX 'strftime';
use YAML::Tiny;

our $VERSION = '0.1.0';
my  $repo    = 'https://github.com/nxadm/idp-sealer-rollover';

### CLI ###
# Defaults
my $config_file = $ENV{IDP_SEALER_ROLLOVER_CONFIG} # Environment value
my %params = (
    idp_image       => undef,
    local_dir       => undef,
    remote_dir      => undef,
    uid             => 'root',
    ssh_user        => 'root';
    ssh_key         => '/root/.ssh/id_rsa';
    sealer_password => undef,
    hosts           => undef,
)
my $help;

GetOptions( 'config=s' => \$config_file, 'help' => \$help)
    or die("Error in command line arguments.\n");
if ($help) { help() and exit 0 }
if (@ARGV != 2) {
    say STDERR 'You need to supply a project and a environment parameter.';
    help();
    exit 1;
}
if ( ! -r $config_file) {
    say STDERR "The configuration file ($config_file) is not readable.";
    say STDERR 'Bailing out...';
    exit 1;
}
my $project     = $ARGV[0];
my $environment = $ARGV[1];

### Configuration ###
my $yaml         = YAML::Tiny->read($config_file);
my $data_all     = $yaml->[0];
my $data_project = $data_all->config->{$project}->{$environment};

# Global
for my $key (keys %params) {
    $param{$key} = $data_all->{$key} if $data_all->{key};
}
# Project
for my $key (keys %params) {
    $param{$key} = $data_project->{$key} if $data_project->{key};
}
# Missing parameters
my $error = 0;
for my $key (keys %params) {
    if (! defined $param{$key}) {
        say "Parameter $key is missing.";
        $error = 1;
    }
}
exit 1 if $error;

# Composed values
my $time   = strftime '%Y%m%d_%H%M%S', localtime;
my $work_dir = "$local_dir/$project/$environment";
my @docker_run = (
    'docker', 'run', '-ti', '--rm', '-v', "$work_dir:/mnt", $idp_image,
    'seckeygen.sh',
    '--storefile', '/mnt/sealer.jks',
    '--storepass', $params{password},
    '--versionfile', '/mnt/sealer.kver',
    '--alias', 'secret'
);

### Main ###
# Create look for the files where the keys are stored
if (! -e "$local_dir/$project") {
    mkdir($env_dir, 0700) or die("Can not create $local_dir/$project: $!");
}
if (! -e "$local_dir/$project/$environment") {
    mkdir($env_dir, 0700) or
    die("Can not create $local_dir/$project/$environment: $!");
}
chmod(0700, $env_dir) or die("Can chmod $env_dir: $!");
chdir($env_dir) or die("Can not chdir to $env_dir: $!");

# Rotate the keys
system(@docker_run) == 0 or do {
    restore();
    say STDERR 'The dockerized sealer update script returned a fail status.';
    say STDERR 'No sealer files were uploaded.';
    exit 1;
};

# Verify the hosts are up and we have write access
for my $host ( @{ $params{hosts} } ) {
    # Test: create the remote directory if not present, create a temporary
    # file and delete it.
    my @ssh_args = (
        'ssh', '-i', $params{ssh_key}, $params{ssh_user} . '@' . $host,
        "mkdir -p $params{remote_dir} && " .
        "touch $params{remote_dir}/$time && " .
        "rm -f $params{remote_dir}/$time" );
    system(@ssh_args) == 0 or do  {
        restore();
        say STDERR "Remote ssh server check failed on ($host).";
        say STDERR 'No sealer files were uploaded.';
        exit 1;
    };
}

# Create a backup
for my $file (qw/sealer.jks sealer.kver/) {
    if (-f $file) {
        copy($file, "${file}_$time") or die("Can not backup $file: $!");
    }
}

# Upload the keys (and rollback if needed)
my (@uploaded, $error);
for my $host ( @{ $params{hosts} } ) {
    my @scp_args = (
        'scp', '-q', '-i', $params{ssh_key}, 'sealer.jks', 'sealer.kver',
        $parmas{user} . '@' . $host . ':' . $params{remote_dir} . '/' );
    system(@scp_args) == 0 or do {
        say STDERR "The sealer files can not be uploaded to $host.";
        say STDERR 'This is serious. Inmediate action is needed!';
        say STDERR "Verify the idp sealer state on $host!";
        $error = 1;
        last;
    };
    my @ssh_args = (
        'ssh', '-i', $params{ssh_key}, $params{ssh_user} . '@' . $host,
        "chmod 400 $params{remote_dir}/* && " .
        "chown -R $params{uid} $params{remote_dir}" );
    system(@ssh_args) == 0 or do {
        say STDERR 'The sealer files can not be to chowned to the application uid.';
        say STDERR 'This is serious. Inmediate action is needed!';
        say STDERR "Verify the idp sealer state on $host!";
        $error = 1;
        last;
    };
    push @uploaded, $host;
}

if ($error) {
    say STDERR "Restoring sealer files.";
    restore();
    for my $host (@uploaded) {
        my @scp_args = (
            'scp', '-q', '-i', $ssh_key, 'sealer.jks', 'sealer.kver',
            $params{user} . '@' . $host . ':' . $params{remote_dir} . '/' );
        system(@scp_args) == 0 or do {
            say STDERR "The sealer files could not be restored on $host.";
            say STDERR 'The idp configuration on ' . $host .
                        'could be in a incoherent state.';
        };
    }
}

exit 0;

### Functions ###
sub help {
    say "\nidp-sealer-rollover:";
    say 'Roll over Idp sealer keys using an IdP docker image, ' .
        "version $VERSION.";
    say "Bugs to $repo.";
    say "\nUsage:";
    say '    idp-sealer-rollover <environment> [-c <configuration file>]';
    say "\nParameters:";
    say '    -c|--config: configuration file';
    say '    (default: environment variable $IDP_SEALER_ROLLOVER_CONFIG)';
    say "    -h|--help:   this help info\n";
}

sub restore {
    if ( -f "sealer.jks_$time" ) {
        move("sealer.jks_$time",  'sealer.jks')  or die($!);
        move("sealer.kver_$time", 'sealer.kver') or die($!);
    }
}
