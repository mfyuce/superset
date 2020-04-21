#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

######################################################################
# PY stage that simply does a pip install on our requirements
######################################################################
ARG PY_VER=3.6.9
FROM python:${PY_VER} AS superset-py

RUN mkdir /app \
        && apt-get update -y \
        && apt-get install -y --no-install-recommends \
            build-essential \
            default-libmysqlclient-dev \
            libpq-dev \
        && rm -rf /var/lib/apt/lists/*

# First, we just wanna install requirements, which will allow us to utilize the cache
# in order to only build if and only if requirements change
COPY ./requirements.txt /app/
RUN cd /app \
        && pip install --no-cache -r requirements.txt


######################################################################
# Node stage to deal with static asset construction
######################################################################
# FROM node:10-jessie AS superset-node

# ARG NPM_BUILD_CMD="build"
# ENV BUILD_CMD=${NPM_BUILD_CMD}

# NPM ci first, as to NOT invalidate previous steps except for when package.json changes
# RUN mkdir -p /app/superset-frontend
# RUN mkdir -p /app/superset/assets
# COPY ./docker/frontend-mem-nag.sh /
# COPY ./superset-frontend/package* /app/superset-frontend/
# RUN /frontend-mem-nag.sh 
# \
#         && cd /app/superset-frontend \
#         && npm ci

# Next, copy in the rest and let webpack do its thing
# COPY ./superset-frontend /app/superset-frontend
# RUN rm -rf /app/superset/static/assets/*
# This is BY FAR the most expensive step (thanks Terser!)
#RUN cd /app/superset-frontend \
#        && npm run ${BUILD_CMD} \
#        && rm -rf node_modules


######################################################################
# Final lean image...
######################################################################
ARG PY_VER=3.6.9
FROM python:${PY_VER} AS lean

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    FLASK_ENV=production \
    FLASK_APP="superset.app:create_app()" \
    PYTHONPATH="/app/pythonpath" \
    SUPERSET_HOME="/app/superset_home" \
    SUPERSET_PORT=8080
# --no-create-home  --no-log-init
RUN useradd --user-group --shell /bin/bash superset \
        && mkdir -p ${SUPERSET_HOME} ${PYTHONPATH} \
        && apt-get update -y \
        && apt-get install -y --no-install-recommends \
            build-essential \
            default-libmysqlclient-dev \
            libpq-dev \
        && rm -rf /var/lib/apt/lists/*

## Lastly, let's install superset itself
COPY ./superset /app/superset
RUN mkdir -p /app/superset-frontend
RUN mkdir -p /app/superset/assets
COPY ./superset-frontend/package* /app/superset-frontend/

COPY --from=superset-py /usr/local/lib/python3.6/site-packages/ /usr/local/lib/python3.6/site-packages/
# Copying site-packages doesn't move the CLIs, so let's copy them one by one
COPY --from=superset-py /usr/local/bin/gunicorn /usr/local/bin/celery /usr/local/bin/flask /usr/bin/
# COPY --from=superset-node /app/superset/static/assets /app/superset/static/assets
# COPY --from=superset-node /app/superset-frontend /app/superset-frontend

COPY setup.py MANIFEST.in README.md /app/
RUN cd /app \
        && chown -R superset:superset * \
        && pip install -e .

COPY ./docker/docker-entrypoint.sh /usr/bin/

WORKDIR /app

USER superset

HEALTHCHECK CMD ["curl", "-f", "http://localhost:8088/health"]

EXPOSE ${SUPERSET_PORT}

ENTRYPOINT ["/usr/bin/docker-entrypoint.sh"]

######################################################################
# Dev image...
######################################################################
FROM lean AS dev

COPY ./requirements-dev.txt ./docker/requirements* /app/

USER root
# RUN /usr/bin/ssh-keygen -A
RUN mkdir /home/superset  
RUN chmod -R 777 /home/superset  


RUN apt-get update \
       && apt-get install -y --no-install-recommends \
            openssh-server \
            supervisor
RUN mkdir -p /var/run/sshd /var/log/supervisor \
        && touch /var/log/supervisor/supervisord.log
RUN chmod -R 777 /var/log/supervisor/
RUN chmod -R 777 /var/run/

COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
# COPY sshd_config /etc/ssh/sshd_config


EXPOSE 2222

# /usr/sbin/sshd -D

# RUN service supervisor start &
# RUN service ssh start &
# CMD ["/usr/bin/supervisord"]
USER superset
RUN mkdir /home/superset/custom_ssh \
       && ssh-keygen -f /home/superset/custom_ssh/ssh_host_rsa_key -N '' -t rsa \
       && ssh-keygen -f /home/superset/custom_ssh/ssh_host_dsa_key -N '' -t dsa \
        && echo '  \n\
        Port 2222  \n\
HostKey /home/superset/custom_ssh/ssh_host_rsa_key  \n\
HostKey /home/superset/custom_ssh/ssh_host_dsa_key  \n\
AuthorizedKeysFile  .ssh/authorized_keys  \n\
ChallengeResponseAuthentication no  \n\
UsePAM yes  \n\
Subsystem   sftp    /usr/lib/ssh/sftp-server  \n\
PidFile /home/superset/custom_ssh/sshd.pid' > /home/superset/custom_ssh/sshd_config \
        && /usr/sbin/sshd -f /home/superset/custom_ssh/sshd_config


USER root

RUN cd /app \
    && pip install --no-cache -r requirements-dev.txt -r requirements-extra.txt \
    && pip install --no-cache -r requirements-local.txt || true
USER superset
