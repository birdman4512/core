#See https://github.com/fluent/fluentd-docker-image/blob/master/HOWTOBUILD.md for details on building custom Fluentd images

ARG FLUENTD_VERSION="latest"
FROM fluent/fluentd:${FLUENTD_VERSION}

#Need to switch to root to install plugins
USER root
# Install the OpenSearch output plugin
RUN fluent-gem install fluent-plugin-opensearch \
    && fluent-gem install fluent-plugin-beats \
    && fluent-gem install fluent-plugin-rewrite-tag-filter \
    && gem sources --clear-all \
    && apt-get purge -y --auto-remove \
        -o APT::AutoRemove::RecommendsImportant=false \
        $buildDeps \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf /tmp/* /var/tmp/* /usr/lib/ruby/gems/*/cache/*.gem \

#Switch back to fluent user
USER fluent

# Use the default entrypoint
ENTRYPOINT ["tini", "--", "/bin/entrypoint.sh"]
CMD ["fluentd"]