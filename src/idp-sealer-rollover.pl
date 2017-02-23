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
my $config_file = $ENV{IDP_SEALER_ROLLOVER_CONFIG}; # Environment value
my %params = (
    uid             => 'root',
    docker_user     => 'root',
    ssh_user        => 'root',
    ssh_key         => '/root/.ssh/id_rsa',
    idp_image       => undef,
    local_dir       => undef,
    remote_dir      => undef,
    sealer_password => undef,
    hosts           => undef,
);
my $help;

GetOptions( 'config=s' => \$config_file, 'help' => \$help)
    or say_and_exit("Error in command line arguments.");
help() if ($help || @ARGV == 0);
if (@ARGV != 2) {
    say_and_exit('You need to supply a project and a environment parameter.')
}
if ( ! -r $config_file) {
    say_and_exit("The configuration file ($config_file) is not readable.");
}
my $project     = $ARGV[0];
my $environment = $ARGV[1];

### Configuration ###
my $yaml             = YAML::Tiny->read($config_file);
my $data_all         = $yaml->[0];
my $data_project     = $data_all->{projects}->{$project};
my $data_project_env =
    $data_all->{projects}->{$project}->{environments}->{$environment};

# Global
for my $level ($data_all, $data_project, $data_project_env) {
    for my $key (keys %params) {
        $params{$key} = $level->{$key} if exists $level->{$key};
    }
}

# Missing parameters
my @missing;
for my $key (keys %params) {
    push @missing, "Parameter $key is missing." unless (defined $params{$key});
}
say_and_exit(@missing);

# Composed values
my $time       = strftime '%Y%m%d_%H%M%S', localtime;
my $work_dir   = "$params{local_dir}/$project/$environment";
my @docker_run = (
    'docker', 'run', '-ti', '--rm', '-v', "$work_dir:/mnt", $params{idp_image},
    'seckeygen.sh',
    '--storefile', '/mnt/sealer.jks',
    '--storepass', $params{sealer_password},
    '--versionfile', '/mnt/sealer.kver',
    '--alias', 'secret'
);

### Main ###
# Create directory for the files where the keys are stored
if (! -e "$params{local_dir}/$project") {
    mkdir("$params{local_dir}/$project", 0700) or
        say_and_exit("Can not create $params{local_dir}/$project: $!");
}
if (! -e "$params{local_dir}/$project/$environment") {
    mkdir("$params{local_dir}/$project/$environment", 0700) or
        say_and_exit(
            "Can not create $params{local_dir}/$project/$environment: $!");
}
chmod(0700, $work_dir) or say_and_exit("Can chmod $work_dir: $!");
chdir($work_dir)       or say_and_exit("Can not chdir to $work_dir: $!");

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
        say_and_exit(
            "Remote ssh server check failed on ($host).",
            'No sealer files were uploaded.'
        );
    }
}

# Create a backup
for my $file (qw/sealer.jks sealer.kver/) {
    if (-f $file) {
        copy($file, "${file}_$time") or
        say_and_exit(
            "Can not backup $file: $!", 'No sealer files were uploaded.'
        );
    }
}

# Rotate the keys
system(@docker_run) == 0 or do {
    restore();
    say_and_exit(
        'The dockerized sealer update script returned a fail status.',
        'No sealer files were uploaded.'
    );
};

# Upload the keys (and rollback if needed)
my @uploaded;
for my $host ( @{ $params{hosts} } ) {
    my @scp_args = (
        'scp', '-q', '-i', $params{ssh_key}, 'sealer.jks', 'sealer.kver',
        $params{ssh_user} . '@' . $host . ':' . $params{remote_dir} . '/' );
    system(@scp_args) == 0 or do {
        say_and_exit(
            "The sealer files can not be uploaded to $host.",
            'This is serious. Inmediate action is needed!',
            "Verify the idp sealer state on $host!"
        );
        last;
    };
    my @ssh_args = (
        'ssh', '-i', $params{ssh_key}, $params{ssh_user} . '@' . $host,
        "chmod 400 $params{remote_dir}/* && " .
        "chown -R $params{uid} $params{remote_dir}" );
    system(@ssh_args) == 0 or do {
        say_and_exit(
            'The sealer files can not be to chowned to the application uid.',
            'This is serious. Inmediate action is needed!',
            "Verify the idp sealer state on $host!"
        );
        last;
    };
    push @uploaded, $host;
}

if (scalar @uploaded != scalar @{ $params{hosts} } ) {
    restore();
    my $error = 0;
    for my $host (@uploaded) {
        my @scp_args = (
            'scp', '-q', '-i', $params{ssh_dir}, 'sealer.jks', 'sealer.kver',
            $params{ssh_user} . '@' . $host . ':' . $params{remote_dir} . '/'
        );
        system(@scp_args) == 0 or do {
            say STDERR "The sealer files could not be restored on $host.";
            sat STDERR 'This is serious. Inmediate action is needed!',
            say STDERR 'The idp configuration on ' . $host .
                        'could be in a incoherent state.';
            $error = 1;
        };
    }
    exit 1 if ($error);
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
    exit 0;
}

sub restore {
    say STDERR "Restoring sealer files.";
    if ( -f "sealer.jks_$time" ) {
        move("sealer.jks_$time",  'sealer.jks')  or die($!);
        move("sealer.kver_$time", 'sealer.kver') or die($!);
    } else {
        say STDERR "Warning: no backupped files found.";
    }
}

sub say_and_exit {
    if (@_) {
        say STDERR $_ for @_;
        say STDERR "Bailing out...";
        exit 1;
    }
}
