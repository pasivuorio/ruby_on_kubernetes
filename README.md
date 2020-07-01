# README

Create kubernetes clusters

## Prerequisites

* Install kubectl:
https://kubernetes.io/docs/tasks/tools/install-kubectl/#install-kubectl-on-macos

* Install doctl:
https://github.com/digitalocean/doctl

* Install ruby 2.7.1 environment and run bundle install (not covered in this doc)

# Configuration and deployment

## Set credentials 

* Rename .env.production.cluster.example as .env.production.cluster and replace it with your credentials (this file will contain all your secrets and will not be placed in git repo)

## Define cluster

* edit config/cluster.yml with your preferred cluster specification

## Define apps

* edit config/applications.yml and add your own apps

## Create cluster

First check that you have cluster name and docker credentials defined in .env.production.cluster

* Call rake kube:cluster:setup from terminal. This will create the cluster in digital ocean and set global services

On first call it will create the cluster automatically if it exists. You can run this multiple times if needed, it will not overwrite existing cluster services.

## Database setup

As database engine we use opensource high availability Postgres service Stolon: https://github.com/sorintlab/stolon

* Call rake kube:db:build to build the stolon docker image (adds postgis geo db extension) and upload it to your repository. Note: you have to make image in your repository public because we run short lived Pod with kubectl to setup the cluster.

On first clean install, call following rake tasks:
* rake kube:db:setup[new], this will setup a postgres clusted and initialize it with new database

If you want to build a new cluster with existing database backup image, call:
* rake kube:db:setup[restore], this will download latest backup from your S3 storage and restore it do your database cluster

If you later need to reinstall database services, call kube:db:setup without parameters so that it will not touch the data

## Redis setup

* Call rake kube:redis:setup to launch redis sentinel cluster

# Elasticsearch setup

* Call rake kube:elastic:setup to launch elasticsearch, kibana and logging services

## Monitoring setup

* Call rake kube:monitoring:setup to launch kubernetes monitoring services and grafana web ui

## Applications setup

You can install all apps with following commands:

* rake kube:apps:build_all will build all apps and upload the docker images to docker hub
* rake kube:apps:setup_all will create the app-specific configuration files and upload to cluster
* rake kube:apps:deploy_all will deploy the apps to the cloud and create domain & certificate changes to match the settings automatically

Individual apps can be installed with:

* rake kube:app_name:build
* rake kube:app_name:setup
* rake kube:app_name:deploy

# Operating services

## Shell access

You can access the ssh shell of each service by entering following commands:
- rake kube:db:shell to access database node shell
- rake kube:app_name:shell to access application shell

## Rails console
- rake kube:app_name:console will launch the rails-console of application

## Database actions

- rake kube:db:backup

 