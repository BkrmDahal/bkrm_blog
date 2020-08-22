# build environment
FROM node:alpine as builder

RUN apk update && apk add --no-cache make git python autoconf g++ libc6-compat libjpeg-turbo-dev libpng-dev nasm

WORKDIR /usr/src/app
COPY . .

RUN yarn install
RUN yarn build
RUN rm -rf ./src ./node_modules /usr/local/lib/node_modules /usr/local/share/.cache/yarn/
RUN mkdir -p /run/nginx

# server environment
FROM nginx:alpine
RUN rm -rf /usr/share/nginx/html/*
COPY nginx.conf /etc/nginx/conf.d/configfile.template
ENV PORT 8080
ENV HOST 0.0.0.0
RUN sh -c "envsubst '\$PORT'  < /etc/nginx/conf.d/configfile.template > /etc/nginx/conf.d/default.conf"
COPY --from=react-build /app/build /usr/share/nginx/html
EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]