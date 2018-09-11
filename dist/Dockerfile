FROM alpine:latest AS sqitch-build
MAINTAINER David E. Wheeler <david@justatheory.com>
ENV BUILDROOT /work

# Install dependencies.
WORKDIR $BUILDROOT
RUN apk add --update build-base curl perl perl-dev gettext openssl openssl-dev tzdata

# Set up time zone. https://wiki.alpinelinux.org/wiki/Setting_the_timezone
RUN cp /usr/share/zoneinfo/UTC /etc/localtime && echo UTC > /etc/timezone && apk del tzdata

# Install cpan and build dependencies.
RUN curl -sL --compressed https://git.io/cpm > cpm && chmod +x cpm
RUN ./cpm install -L local --verbose --no-test Module::Build Menlo::CLI::Compat Dist::Zilla

# Copy source, install dzil build depdendencies, build src dir, install tmp dependencies.
COPY . .
ENV PERL5LIB $BUILDROOT/local/lib/perl5
RUN ./local/bin/dzil authordeps --missing | xargs ./cpm install -L local --verbose --no-test
RUN ./local/bin/dzil build --in src
RUN ./cpm install -L local --verbose --no-test --with-recommends --cpanfile src/cpanfile

# Install build/test dependencies, build, test, bundle.
WORKDIR $BUILDROOT/src
RUN perl Build.PL --quiet --install_base /app --etcdir /etc && ./Build test && ./Build bundle

# Copy to the final image without all the build stuff.
FROM alpine:latest
RUN apk add --update perl tzdata
RUN cp /usr/share/zoneinfo/UTC /etc/localtime && echo UTC > /etc/timezone && apk del tzdata
COPY --from=sqitch-build /app .
ENTRYPOINT ["/bin/sqitch"]
CMD ["--help"]
