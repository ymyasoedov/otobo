# This is the build file for the OTOBO web docker image.
# See also README_DOCKER.md.

# use the latest Perl on Debian 10 (buster). As of 2020-07-02.
# cpanm is already installed
FROM perl:5.32.0-buster

USER root

# install some required Debian packages
RUN apt-get update \
    && apt-get -y --no-install-recommends install tree vim nano default-mysql-client cron \
    && rm -rf /var/lib/apt/lists/*

# We want an UTF-8 console
ENV LC_ALL C.UTF-8
ENV LANG C.UTF-8

# A minimal copy so that the Docker cache is not busted
COPY cpanfile ./cpanfile

# Found no easy way to install with --force in the cpanfile. Therefore install
# the modules with ignorable test failures with the option --force.
# Note that the modules in /opt/otobo/Kernel/cpan-lib are not considered by cpanm.
# This hopefully reduces potential conflicts.
RUN cpanm --force XMLRPC::Transport::HTTP Net::Server Linux::Inotify2
RUN cpanm --with-feature=db:mysql --with-feature=plack --with-feature=devel:dbviewer --with-feature=div:bcrypt --with-feature=performance:json --with-feature=mail:imap --with-feature=mail:sasl --with-feature=div:ldap --with-feature=performance:csv --with-feature=div:xslt --with-feature=performance:redis --with-feature=devel:test --installdeps .

# create the otobo user
#   --user-group            create group 'otobo' and add the user to the created group
#   --home-dir /opt/otobo   set $HOME of the user
#   --create-home           create /opt/otobo
#   --shell /bin/bash       set the login shell, not used here because otobo is system user
#   --comment 'OTOBO user'  complete name of the user
ENV OTOBO_USER  otobo
ENV OTOBO_GROUP otobo
ENV OTOBO_HOME  /opt/otobo
RUN useradd --user-group --home-dir $OTOBO_HOME --create-home --shell /bin/bash --comment 'OTOBO user' $OTOBO_USER

# copy the OTOBO installation to /opt/otobo and use it as the working dir
# skip the files set up in .dockerignore
COPY --chown=$OTOBO_USER:$OTOBO_GROUP . $OTOBO_HOME
WORKDIR $OTOBO_HOME

# uncomment these steps when strange behavior must be investigated
#RUN echo "'$OTOBO_HOME'"
#RUN whoami
#RUN pwd
#RUN uname -a
#RUN ls -a
#RUN tree Kernel
#RUN false

# Under Docker the Elasticsearch Daemon is running on the host 'elastic' instead of '127.0.0.1'.
# The webservice configuration is in a YAML file and it is not obvious how
# to change settings for webservices.
# So we take the easy was out and do the change directly in the XML file,
# before installer.pl has run.
# Doing this already in the initial database insert allows installer.pl
# to pick up the changed host and to check whether Elasticsearch is available.
RUN perl -p -i.orig -e "s{Host: http://localhost:9200}{Host: http://elastic:9200}" scripts/database/otobo-initial_insert.xml

# Some initial setup.
# Create dirs.
# Create ARCHIVE
# Enable bash completion.
# Activate the .dist files.
# Config.pm.docker.dist will be copied to Config.pm in entrypoint.sh,
# unless Config.pm already exists
RUN install -d var/stats var/packages var/article \
    && bin/otobo.CheckSum.pl -a create \
    && (echo ". ~/.bash_completion" >> .bash_aliases ) \
    && cp Kernel/Config.pod.dist Kernel/Config.pod \
    && cd var/cron && for foo in *.dist; do cp $foo `basename $foo .dist`; done

# Generate and install the crontab for the user $OTOBO_USER.
# Explicitly set PATH as the required perl is located in /usr/local/bin/perl.
# var/tmp is created by $OTOBO_USER as bin/Cron.sh uses this dir.
USER $OTOBO_USER
RUN mkdir -p var/tmp \
    && echo "# File added by Dockerfile"                             >  var/cron/aab_path \
    && echo "# Let '/usr/bin/env perl' find perl in /usr/local/bin"  >> var/cron/aab_path \
    && echo "PATH=/usr/local/bin:/usr/bin:/bin"                      >> var/cron/aab_path \
    && ./bin/Cron.sh start \
    && cp scripts/vim/.vimrc .

# First set permissions.
# At this point /opt/otobo looks fairly sane. But we might have a previous
# version of OTOBO already installed in a volume.
# Therefore move /opt/otobo out of the way.
# But make sure that the empty die /opt/otobo remains and stays writable by $OTOBO_USER.
# Merging current and next version is left to entrypoint.sh.
# TODO: simplify
USER root
RUN otobo_next="/var/otobo/otobo_next" \
    && perl bin/docker/set_permissions.pl \
    && install --group $OTOBO_GROUP --owner $OTOBO_USER -d $otobo_next \
    && install --group $OTOBO_GROUP --owner $OTOBO_USER bin/docker/entrypoint.sh /var/otobo \
    && touch /var/otobo/upgrade.log \
    && chown $OTOBO_USER:$OTOBO_GROUP /var/otobo/upgrade.log \
    && chown $OTOBO_USER:$OTOBO_GROUP $OTOBO_HOME \
    && mv $OTOBO_HOME/* $otobo_next \
    && touch $otobo_next/docker_firsttime \
    && chown $OTOBO_USER:$OTOBO_GROUP $otobo_next/docker_firsttime

# start the webserver
# start the OTOBO daemon
# start the Cron watchdog
# Tell the webapplication that it runs in a container.
# The entrypoint takes one command: 'web' or 'cron', web switches to OTOBO_USER
ENV OTOBO_RUNS_UNDER_DOCKER 1
ENTRYPOINT ["/var/otobo/entrypoint.sh"]
