# Shibboleth IdP3 Data Sealer Rollover.

idp-sealer-rollover does a rollover of the data sealer files and uploads them
to the target servers. Its main use case is in a clustering mode when several
Shibboleth IdP 3 backends share the dame data sealer data. Ideally it should
be run from an scheduler like cron (cron file included as
idp-sealer-rollover.cron).

The Shibboleth IdP 3 binaries needed to create and rollover the data sealer
files are encapuslated using Docker. The size of the image is small by using
an Alpine image and keeping only the IdP files needed for the key management.
In case you don't want to use the image on the Docker Hub, you can create
you own with the Dockerfile in de /utils directory.

The idp-sealer-rollover is an executable created from the source in
src/idp-sealer-rollover.pl and its dependencies (YAML::Tiny).

# Usage

```
$ idp-sealer-rollover <project> <environment>
```
E.g.
```
$ idp-sealer-rollover idp test
$ idp-sealer-rollover idp quality
$ idp-sealer-rollover idp production
```

# Configuration

A commented configuration is included as idp-sealer-rollover.yaml.


