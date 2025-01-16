#!/usr/bin/env sh
set -euo pipefail
trap trapexit EXIT SIGTERM

TEMPDIR=$(mktemp -d)
TEMPLOG="$TEMPDIR/tmplog"
TEMPERR="$TEMPDIR/tmperr"
LASTCMD=""
WGETOPT="-t 1 -T 15 -q"
DEVDEPS="npm g++ make gcc git python3-dev musl-dev libffi-dev openssl-dev"
NPMURL="https://github.com/NginxProxyManager/nginx-proxy-manager"

cd $TEMPDIR
touch $TEMPLOG

# Helpers
log() {
  logs=$(cat $TEMPLOG | sed -e "s/34/32/g" | sed -e "s/info/success/g");
  clear && printf "\033c\e[3J$logs\n\e[34m[info] $*\e[0m\n" | tee $TEMPLOG;
}
runcmd() {
  LASTCMD=$(grep -n "$*" "$0" | sed "s/[[:blank:]]*runcmd//");
  if [[ "$#" -eq 1 ]]; then
    eval "$@" 2>$TEMPERR;
  else
    $@ 2>$TEMPERR;
  fi
}
trapexit() {
  status=$?

  if [[ $status -eq 0 ]]; then
    logs=$(cat $TEMPLOG | sed -e "s/34/32/g" | sed -e "s/info/success/g")
    clear && printf "\033c\e[3J$logs\n";
  elif [[ -s $TEMPERR ]]; then
    logs=$(cat $TEMPLOG | sed -e "s/34/31/g" | sed -e "s/info/error/g")
    err=$(cat $TEMPERR | sed $'s,\x1b\\[[0-9;]*[a-zA-Z],,g' | rev | cut -d':' -f1 | rev | cut -d' ' -f2-)
    clear && printf "\033c\e[3J$logs\e[33m\n$0: line $LASTCMD\n\e[33;2;3m$err\e[0m\n"
  else
    printf "\e[33muncaught error occurred\n\e[0m"
  fi
  # Cleanup
  rm -rf $TEMPDIR
  apk del $DEVDEPS &>/dev/null
}

# Check for previous install
if [ -f /etc/init.d/npm ]; then
  log "Stopping services"
  rc-service npm stop &>/dev/null
  rc-service openresty stop &>/dev/null
  sleep 2

  log "Cleaning old files"
  rm -rf /app \
  /var/www/html \
  /etc/nginx \
  /var/log/nginx \
  /var/lib/nginx \
  /var/cache/nginx &>/dev/null

  log "Removing old dependencies"
  apk del certbot $DEVDEPS &>/dev/null
fi

log "Checking for latest openresty repository"
. /etc/os-release
_alpine_version=${VERSION_ID%.*}
if [ ! -f /etc/apk/keys/admin@openresty.com-5ea678a6.rsa.pub ]; then
  runcmd 'wget $WGETOPT -P /etc/apk/keys/ http://openresty.org/package/admin@openresty.com-5ea678a6.rsa.pub'
fi

_repository_version=$(wget $WGETOPT "http://openresty.org/package/alpine/" -O - | grep -Eo "[0-9]{1}\.[0-9]{1,2}" | sort -uVr | head -n1)
_repository_version=$(printf "$_repository_version\n$_alpine_version" | sort -V | head -n1)
_repository="http://openresty.org/package/alpine/v$_repository_version/main"
grep -q 'openresty.org' /etc/apk/repositories &&
  sed -i "/openresty.org/c\\$_repository/" /etc/apk/repositories || echo $_repository >> /etc/apk/repositories

log "Updating container OS"
echo "fs.file-max = 65535" > /etc/sysctl.conf
runcmd apk update
runcmd apk upgrade

log "Installing dependencies"
runcmd 'apk add python3 openresty nodejs yarn openssl apache2-utils logrotate $DEVDEPS'

log "Setting up python"
python3 -m venv /opt/certbot/
. /opt/certbot/bin/activate
runcmd pip install --no-cache-dir -U pip
runcmd pip install --no-cache-dir cryptography==3.3.2 cffi certbot
deactivate

log "Checking for latest NPM release"
runcmd 'wget $WGETOPT -O ./_latest_release $NPMURL/releases/latest'
_latest_version=$(basename $(cat ./_latest_release | grep -wo "expanded_assets/v.*\d") | cut -d'v' -f2)

log "Downloading NPM v$_latest_version"
runcmd 'wget $WGETOPT -c $NPMURL/archive/v$_latest_version.tar.gz -O - | tar -xz'
cd ./nginx-proxy-manager-$_latest_version

log "Setting up environment"
ln -sf /usr/bin/python3 /usr/bin/python
ln -sf /usr/bin/pip3 /usr/bin/pip
ln -sf /usr/bin/certbot /opt/certbot/bin/certbot
ln -sf /usr/local/openresty/nginx/sbin/nginx /usr/sbin/nginx
ln -sf /usr/local/openresty/nginx/ /etc/nginx

sed -i "s+0.0.0+$_latest_version+g" backend/package.json
sed -i "s+0.0.0+$_latest_version+g" frontend/package.json
sed -i 's+^daemon+#daemon+g' docker/rootfs/etc/nginx/nginx.conf
NGINX_CONFS=$(find "$(pwd)" -type f -name "*.conf")
for NGINX_CONF in $NGINX_CONFS; do
  sed -i 's+include conf.d+include /etc/nginx/conf.d+g' "$NGINX_CONF"
done

mkdir -p /var/www/html /etc/nginx/logs
cp -r docker/rootfs/var/www/html/* /var/www/html/
cp -r docker/rootfs/etc/nginx/* /etc/nginx/
cp docker/rootfs/etc/letsencrypt.ini /etc/letsencrypt.ini
cp docker/rootfs/etc/logrotate.d/nginx-proxy-manager /etc/logrotate.d/nginx-proxy-manager
ln -sf /etc/nginx/nginx.conf /etc/nginx/conf/nginx.conf
rm -f /etc/nginx/conf.d/dev.conf

mkdir -p /tmp/nginx/body \
/tmp/nginx/body \
/run/nginx \
/data/nginx \
/data/custom_ssl \
/data/logs \
/data/access \
/data/nginx/default_host \
/data/nginx/default_www \
/data/nginx/proxy_host \
/data/nginx/redirection_host \
/data/nginx/stream \
/data/nginx/dead_host \
/data/nginx/temp \
/var/lib/nginx/cache/public \
/var/lib/nginx/cache/private \
/var/cache/nginx/proxy_temp

chmod -R 777 /var/cache/nginx
chown root /tmp/nginx
echo resolver "$(awk 'BEGIN{ORS=" "} $1=="nameserver" {print ($2 ~ ":")? "["$2"]": $2}' /etc/resolv.conf);" > /etc/nginx/conf.d/include/resolvers.conf

if [ ! -f /data/nginx/dummycert.pem ] || [ ! -f /data/nginx/dummykey.pem ]; then
  log "Generating dummy SSL certificate"
  runcmd 'openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 -subj "/O=Nginx Proxy Manager/OU=Dummy Certificate/CN=localhost" -keyout /data/nginx/dummykey.pem -out /data/nginx/dummycert.pem'
fi

mkdir -p /app/global /app/frontend/images
cp -r backend/* /app
cp -r global/* /app/global

log "Building frontend"
cd ./frontend
export NODE_ENV=development
runcmd yarn install --network-timeout 100000
runcmd yarn build
cp -r dist/* /app/frontend
cp -r app-images/* /app/frontend/images

log "Initializing backend"
rm -rf /app/config/default.json &>/dev/null
if [ ! -f /app/config/production.json ]; then
cat << 'EOF' > /app/config/production.json
{
  "database": {
    "engine": "knex-native",
    "knex": {
      "client": "sqlite3",
      "connection": {
        "filename": "/data/database.sqlite"
      }
    }
  }
}
EOF
fi
cd /app
export NODE_ENV=development
runcmd yarn install

log "Creating NPM service"
cat << 'EOF' > /etc/init.d/npm
#!/sbin/openrc-run
description="Nginx Proxy Manager"

command="/usr/bin/node"
command_args="index.js --abort_on_uncaught_exception --max_old_space_size=250"
command_background="yes"
directory="/app"

pidfile="/var/run/npm.pid"
output_log="/var/log/npm.log"
error_log="/var/log/npm.err"

depends () {
  before openresty
}

start_pre() {
  mkdir -p /tmp/nginx/body \
  /data/letsencrypt-acme-challenge

  export NODE_ENV=production
}

stop() {
  pkill -9 -f node
  return 0
}

restart() {
  $0 stop
  $0 start
}
EOF
chmod a+x /etc/init.d/npm
rc-update add npm boot &>/dev/null
rc-update add openresty boot &>/dev/null
rc-service openresty stop &>/dev/null

log "Starting services"
runcmd rc-service openresty start
runcmd rc-service npm start

IP=$(ip a s dev eth0 | sed -n '/inet / s/\// /p' | awk '{print $2}')
log "Installation complete

\e[0mNginx Proxy Manager should be reachable at the following URL.

      http://${IP}:81
"
