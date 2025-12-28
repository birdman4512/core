# Declare args
ARG OPENSEARCH_VERSION

FROM opensearchproject/opensearch:${OPENSEARCH_VERSION:-latest}

USER root
RUN yum check-update && \
	yum install openssl pip jq -y 
	
#ADD ./entrypoint.sh /entrypoint.sh

CMD /bin/bash /entrypoint.sh
	 