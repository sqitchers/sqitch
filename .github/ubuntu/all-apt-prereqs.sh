set -e

sudo apt-get update -qq
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -qq \
    libicu-dev gettext aspell-en software-properties-common \
    curl unixodbc-dev odbcinst unixodbc \
    default-jre \
    firebird-dev firebird3.0-utils \
    mysql-client default-libmysqlclient-dev \
    libarchive-tools
cat t/odbc/odbcinst.ini | sudo tee -a /etc/odbcinst.ini
