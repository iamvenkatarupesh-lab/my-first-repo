# Tiny nginx image that serves the site/ folder on port 80
FROM nginx:1.27-alpine

# Remove default nginx page
RUN rm -rf /usr/share/nginx/html/*

# Copy our static site
COPY site/ /usr/share/nginx/html/

EXPOSE 80
