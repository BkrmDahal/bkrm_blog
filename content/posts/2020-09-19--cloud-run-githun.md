---
title: Deploy Docker Image using Github Actions to Google cloud Run
date: "2020-09-19T22:12:03.284Z"
template: "post"
draft: false
slug: "deploy-docker-using-github-actions-to-google-cloud-run"
category: "CI/CD"
tags:
  - "docker"
  - "gcp"
  - "github-actions"
  - "cloud-run"
  - "serverless"
  - "CI/CD"
description: "Deploy docker images automatically from github to cloud run using github actions. Cloud run is serveless similar to lambda so you are only charged when container is serving request. Major different between aws lamdha or google function and cloud run is cloud run can deploy docker images, which is life saver as majority of projects are already dockerize."
socialImage: "media/cloud_run/deploy-docker-using-github-actions-to-google-cloud-run.png"
---

![Deploy Docker using Github Actions to Google cloud RUn](/media/cloud_run/deploy-docker-using-github-actions-to-google-cloud-run.png)
I love serverless architecture. Serverless is not sliver bullet for all workloads but when used properly (depending on requirement) you can save more than 95%+ of cost. 
In this blog, I am going to explain how to set up CD to [cloud run](https://cloud.google.com/run) in github repo using [github action](https://github.com/features/actions). We will be taking this blog as example. This blog is build on top of gatsby. So we will first make a build using node, put build file only on nginx docker, push to google docker repo and than deploy to cloud run. You should be able to follow this tutorials using google free tier resources.

What is cloud run?
> Cloud run is fully managed compute platform for deploying and scaling containerized applications quickly, securely. 

### Steps:
1. Make Dockerfile for you project and run your project on ``port 8080`` (your program should run on 8080. Google only map 8080 to 80 while deploying).

```
# build environment
FROM node:alpine as builder
RUN apk update && apk add --no-cache make git python autoconf g++ libc6-compat libjpeg-turbo-dev libpng-dev nasm
WORKDIR /usr/src/app
COPY . .
RUN yarn install
RUN yarn build

# server environment
FROM nginx:alpine
RUN rm -rf /usr/share/nginx/html/*
COPY nginx.conf /etc/nginx/conf.d/configfile.template
ENV PORT 8080
ENV HOST 0.0.0.0
RUN sh -c "envsubst '\$PORT'  < /etc/nginx/conf.d/configfile.template > /etc/nginx/conf.d/default.conf"
COPY --from=builder /usr/src/app/public /usr/share/nginx/html
EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]
```

2. Make project into google cloud and get gcloud service key with the following permissions:
    - Service Account User
    - Cloud Run Admin
    - Storage Admin
    - Cloud run Service Agent

3. Convert your google service key to base64 encoding and add to github secrets in setting as ``GCP_CLOUD_RUN_SERVICE_KEY``. Also add project id as ``GCP_PROJECT_ID`` to secrets.

4. Add github actions in ``.github/workflows/docker-publish.yml``

```
name: Docker

on:
  push:
    # Publish `master` as Docker `latest` image.
    branches:
      - master

    # Publish `v1.2.3` tags as releases.
    tags:
      - v*

  # Run tests for any PRs.
  pull_request:

env:
  # TODO: Change variable to your image's name.
  IMAGE_NAME: bkrm-blog

jobs:

  # Push image to GitHub Packages.
  # See also https://docs.docker.com/docker-hub/builds/
  push:
    # Ensure test job passes before pushing image.
    # needs: test

    runs-on: ubuntu-latest
    if: github.event_name == 'push'

    steps:
      - uses: actions/checkout@v2

      - name: Build image
        run: docker build . --file Dockerfile --tag $IMAGE_NAME

      - name: Log into registry
        run: echo "${{ secrets.GITHUB_TOKEN }}" | docker login docker.pkg.github.com -u ${{ github.actor }} --password-stdin

      - name: Push image
        run: |
          IMAGE_ID=docker.pkg.github.com/${{ github.repository }}/$IMAGE_NAME
          # Change all uppercase to lowercase
          IMAGE_ID=$(echo $IMAGE_ID | tr '[A-Z]' '[a-z]')
          # Strip git ref prefix from version
          VERSION=$(echo "${{ github.ref }}" | sed -e 's,.*/\(.*\),\1,')
          # Strip "v" prefix from tag name
          [[ "${{ github.ref }}" == "refs/tags/"* ]] && VERSION=$(echo $VERSION | sed -e 's/^v//')
          # Use Docker `latest` tag convention
          [ "$VERSION" == "master" ] && VERSION=latest
          docker tag $IMAGE_NAME $IMAGE_ID:$VERSION
          docker push $IMAGE_ID:$VERSION
          
          # tag image for gcp
          IMAGE_ID_GCP=asia.gcr.io/${{ secrets.GCP_PROJECT_ID }}/bkrmblog:$VERSION
          echo $IMAGE_ID_GCP
          docker tag $IMAGE_ID:$VERSION $IMAGE_ID_GCP
          
      - name: Deploy to Cloud Run
        uses: stefda/action-cloud-run@v1.0
        with:
          image: asia.gcr.io/${{ secrets.GCP_PROJECT_ID }}/bkrmblog
          service: bkrm-blog
          project: ${{ secrets.GCP_PROJECT_ID }}
          region: asia-southeast1
          service key: ${{ secrets.GCP_CLOUD_RUN_SERVICE_KEY }}
```

5. Thats all, now after each commit your code will be deployed to cloud run. You can get url for service from cloud run dashboard. You can also use ``manage custom domin`` feature in cloud run to add your own subdomain or even map  main domain.

This blog is build using these blocks checkout the github repo [bkrm repo](https://github.com/BkrmDahal/bkrm_blog).
  
Quote from book I am reading:  

> _“It's easy to say yes. Yes to another feature, yes to an overly optimistic deadline, yes to a mediocre design. Soon, the stack of things you've said yes to grows so tall you cant even see the things you should really be doing”_ 
> 
> __― Rework__