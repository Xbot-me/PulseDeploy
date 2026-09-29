# Managed by PulseDeploy - shared request handling for the Laravel API.
# Included by both the public server and the loopback-only internal server.
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;

gzip on;
gzip_vary on;
gzip_proxied any;
gzip_comp_level 5;
gzip_min_length 512;
gzip_types application/json application/javascript text/css text/plain text/xml
           application/xml image/svg+xml;

# Dotfiles (.env, .git, ...) except ACME challenges
location ~ /\.(?!well-known/) {
    return 404;
}

location = /favicon.ico { access_log off; log_not_found off; }
location = /robots.txt  { access_log off; log_not_found off; }

location ~* \.(?:jpg|jpeg|png|gif|ico|svg|webp|avif|woff2?|css|js)$ {
    expires 30d;
    access_log off;
    add_header Cache-Control "public";
    try_files $uri =404;
}

location / {
    try_files $uri $uri/ /index.php?$query_string;
}

location ~ \.php$ {
    try_files $uri =404;
    include fastcgi_params;
    # $realpath_root resolves the "current" symlink, so OPcache and PHP see the
    # release directory and a deploy switches over atomically.
    fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
    fastcgi_param DOCUMENT_ROOT $realpath_root;
    fastcgi_pass unix:@PHP_SOCK@;
    fastcgi_read_timeout 60;
    fastcgi_buffers 16 16k;
    fastcgi_buffer_size 32k;
}
