FROM alpine:latest
MAINTAINER David E. Wheeler <david@justatheory.com>
ENV BUILDROOT /work

# Install dependencies.
WORKDIR ${BUILDROOT}
RUN apk add --update build-base curl perl perl-dev gettext openssl openssl-dev
RUN curl -sL --compressed https://git.io/cpm > cpm && chmod +x cpm
RUN ./cpm install -L local --verbose --no-test Module::Build Menlo::CLI::Compat Dist::Zilla

# Copy source, install build depdendencies, build src dir, install tmp dependencies.
COPY . .
ENV PERL5LIB ${BUILDROOT}/local/lib/perl5
RUN ./local/bin/dzil authordeps --missing | xargs ./cpm install -L local --verbose --no-test
RUN ./local/bin/dzil build --in src
RUN ./cpm install -L local --verbose --no-test --with-recommends --cpanfile src/cpanfile

# Install build/test dependencies, build, test, bundle.
WORKDIR ${BUILDROOT}/src
RUN perl Build.PL --quiet --install_base /sqitch --etcdir /etc && ./Build test && ./Build bundle
