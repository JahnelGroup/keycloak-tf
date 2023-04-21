# Example of running highly available keycloak in AWS ECS Fargate

This repository is an example of how to run and configure keycloak in a highly available manner and deploy it to AWS.

## Why does this need to exist?

AWS deployments can't use the standard UDP methods that keycloak uses in order to find it's peers and distribute its Infinispan cache appropriately so sessions will become lost when the load balancer switches the users session from one server to the next.

In order to make this work in AWS, Keycloak uses an s3 bucket to upload and maintain a list of peers that keycloak can communicate with. For example the s3 file `keycloak-s3-ping-20230420145703605200000002/ISPN/c9af7db6-7db9-4f1e-a70b-7896431d4aab.ip-10-0-101-177-32219.list` contains the following data currently

```
ip-10-0-101-177-32219 	c9af7db6-7db9-4f1e-a70b-7896431d4aab 	10.0.101.177:7800 	T
ip-10-0-102-124-32711 	21c25d34-a003-4442-96f8-1ccf3ae8b983 	10.0.102.124:7800 	F
```

which allows the two keycloak peers to find each other and then begin to distribute their caches amungst themselves.

## What should I look at in this repo?

Most of the repo is standard infrastructure for setting up a publicly available ECS cluster behind a load balancer with SSL certificates. So you can basically ignore the `alb.tf`, `ecr.tf`, `rds.tf`, and `route-53.tf` files.

The one file that is interesting is how the Keycloak image is built (the `Dockerfile`) and how it is deployed (the `ecs.tf`) file.

In the `Dockerfile` (as well as the jars in the `keycloak-providers` file in the root of the repo) you'll notice that there are additional providers added to the image before it is built.

```
COPY ./keycloak-providers/* /opt/keycloak/providers
```

Without this the S3_PING provider couldn't be found when selecting the ec2 stack (`--cache-stack=ec2` in the Dockerfile build command).

In the `ecs.tf` file the `aws_ecs_task_definition` is where most of the Keycloak specific configurations are recorded. Primarily the KC_PROXY environment variable needs to be set to `edge` so that the load balancer can be running in HTTPS mode but communicate to the containers over HTTP. Next, the `JAVA_OPS_APPEND` needs to be configured to setup the s3 region and bucket name that will be used for the S3_PING cache discovery as well as the cache stack is provided again as KC_CACHE_STACK=ec2. Finally, the ports 7800 and 57800 are used for the peers to be able to communicate with each other and need to be allowed to communicate with security group configurations.

The one thing that isn't represented in this repository is using a custom theme but that can be accomplished by adding the following line to the Dockerfile

```
COPY ./themes /opt/keycloak/themes
```

P.S. All the keycloak providers were downloaded directly from https://mvnrepository.com/
P.S.S. this post is where I figured out what providers were necessary to copy into the image during build https://keycloak.discourse.group/t/keycloak-cluster-jgroups-infinispan-on-ec2/18208/8

## How is this code deployed?

The first thing to do is to update the variables at the top of the make file to point to your ECR repo, AWS profile, and AWS region. Set the TAG to whatever makes sense to you. This tag is used to bump the image version without havingto mess with the base Keycloak version.

There is a bit of a chicken and egg problem here but you should now be able to run `terraform apply` to stand up the initial repository.

The deploy will hang while trying to verify the SSL certificate so while it is hanging you can go and copy the NS settings out of route53 into your domain DNS settings and eventually the SSL certificate will finish provisioning and terraform will finish deploying.

At this point ECS will try to start the services and tasks necessary to run Keycloak but the images won't exist. To fix this run `make push` which will build keycloak locally and push a copy into the ECR repo that was created by terraform in the previous step. You'll need to update the Makefile to contain a reference to the ECR repo that was just created.

For normal work you'll just need to do a `make push` to push up a new image, update the image tag in `variables.tf`, and run `terraform apply` which will redeploy ECS with your new image.
