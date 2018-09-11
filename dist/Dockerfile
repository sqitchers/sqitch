FROM alpine:latest AS sqitch-build
MAINTAINER David E. Wheeler <david@justatheory.com>
ENV BUILDROOT /work

# Install system dependencies.
WORKDIR $BUILDROOT
RUN apk add --update build-base curl perl perl-dev gettext tzdata \
    libressl libressl-dev zlib-dev \
    sqlite postgresql-dev mysql unixodbc-dev

# Set up time zone. https://wiki.alpinelinux.org/wiki/Setting_the_timezone
RUN cp /usr/share/zoneinfo/UTC /etc/localtime && echo UTC > /etc/timezone && apk del tzdata

# Install cpan and build dependencies.
RUN curl -sL --compressed https://git.io/cpm > cpm && chmod +x cpm
RUN ./cpm install -L local --verbose --no-test Module::Build Menlo::CLI::Compat Dist::Zilla

# Copy source, install author dependencies, build src.
COPY . .
ENV PERL5LIB $BUILDROOT/local/lib/perl5
RUN ./local/bin/dzil authordeps --missing | xargs ./cpm install -L local --verbose --no-test
RUN ./local/bin/dzil build --in src

# Install dependencies. Required for ./Build test below.
RUN ./cpm install -L local --verbose --no-test --with-recommends --cpanfile src/cpanfile

# XXX Sadly can't use this in the previous command:
#    --feature sqlite --feature postgres --feature mysql \
# Because the cpanfile does not have the features. Issue:
# https://github.com/karenetheridge/Dist-Zilla-Plugin-OptionalFeature/issues/3

# Build, test, bundle.
WORKDIR $BUILDROOT/src
RUN perl Build.PL --quiet --install_base /app --etcdir /etc \
    --with sqlite --with postgres --with mysql \
    && ./Build test && ./Build bundle

# Copy to the final image without all the build stuff.
FROM alpine:latest
RUN apk add --update perl tzdata less sqlite postgresql-client mysql-client unixodbc
RUN cp /usr/share/zoneinfo/UTC /etc/localtime && echo UTC > /etc/timezone && apk del tzdata
COPY --from=sqitch-build /app .
COPY --from=sqitch-build /etc /etc/

# Set up environment, entrypoint, and default command.
ENV TERM xterm-256color
ENV HOME /home
WORKDIR /repo
ENTRYPOINT ["/bin/sqitch"]
CMD ["help"]
