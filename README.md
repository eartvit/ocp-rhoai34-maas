# What this repo provides
There are three scripts and three configuration files to adjust the scripts execution outcome.
The first script is `setup-cluster.sh` which will configure a vanilla one node openshift cluster to have RHOAI 3.4 with MaaS installed.
The script assumes the cluster is running on AWS.

The second script, `setup-maas.sh`, must be executed after the first script completes without errors. The outcome of the second script is an instance of RHOAI 3.4 with MaaS capability enabled.

The third script is optional, to enable mlflow as part of the RHOAI 3.4 configuration.

These scripts have been tested and verified on an OpenShift 4.20 cluster only! 

# Guide
1. Clone the repo to your machine.
2. Ensure you have an OpenShift 4.20 cluster (or above - but in this case you need to update the ODF version to match OCP version).
3. Create an `users.httpd` file in the folder where you cloned this repo. If you create somewhere else, then make sure you update the `HTPASSWD_PATH` variable inside the setup.conf
4. The `users.httpd` must contain a user that you will assign as cluster-admin. The script default expects this user to be `clusteradmin`. If you want a different user name, please update the `ADMIN_USER` in the setup.conf file.
5. Run `setup-cluster.sh`.
6. Run `setup-maas.sh`.
7. (Optional) Run `setup-mlflow.sh` if you want to use MLFlow inside RHOAI 3.4.

Notes:
1. The scripts will require approximately 30 and 10 minutes, respectively, to execute.
2. Currently, the RHCL must be set to manual and version 1.3.0. (version 1.4.0 breaks RHOAI).

Enjoy Model as a Service on Red Hat OpenShift AI!
