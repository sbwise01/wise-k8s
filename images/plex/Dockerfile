FROM --platform=linux/amd64 index.docker.io/plexinc/pms-docker:1.43.0.10492-121068a07

RUN apt update && apt install -y rsync postgresql-client python3 vim

COPY hashMovies.py /usr/bin
RUN chmod 755 /usr/bin/hashMovies.py
