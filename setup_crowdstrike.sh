#!/bin/bash

log_message() {
  local message="$1"
  local severity="${2^^}"
  local timestamp=$(date +"%Y-%m-%dT%H:%M:%S.%3N%z" | sed 's/\(..\)$/.\1/')
  local accepted_severities=("DEBUG" "INFO" "WARN" "ERROR" "CRITICAL")
  if [[ ! " ${accepted_severities[@]} " =~ " ${severity} " ]]; then
    severity="INFO" # Default to INFO if not matched
  fi
  echo "[$timestamp] [$severity] $message"
}

# Retry function for apt-get commands to avoid lock issues
retry_apt_get() {
  local n=0
  local try=5
  local cmd="$*"
  until [ $n -ge $try ]
  do
    $cmd && break
    n=$((n+1))
    echo "Attempt $n/$try failed"
    sleep 5
  done
}

# Install Updates
export DEBIAN_FRONTEND=noninteractive
retry_apt_get sudo apt-get -yqq update
retry_apt_get sudo apt-get -yqq install dos2unix jq net-tools unzip

##################################################################################################

##################################################################################################
# Disabling Kernel Updates
log_message "Disabling Kernel Updates"

IMG_VERSION=$(dpkg --list | grep linux-image | head -1 | awk '{ print $2 }')
HDR_VERSION=$(dpkg --list | grep linux-headers | head -1 | awk '{ print $2 }')
sudo apt-mark hold linux-image-gcp linux-headers-gcp
sudo apt-mark hold "$IMG_VERSION" "$HDR_VERSION"

##################################################################################################
# Install Kubernetes

log_message "Auto Install Kubernetes"
su - ubuntu

# update the ubuntu config to not popup service to update
log_message "configuring ubuntu to not generate any popup during update ======="
sudo sed -i "/#\$nrconf{restart} = 'i';/s/.*/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf

log_message "Docker Installation"
retry_apt_get sudo apt-get update
retry_apt_get sudo apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    jq \
    lsb-release

sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

retry_apt_get sudo apt-get update
retry_apt_get sudo apt-get install -y docker-ce docker-ce-cli containerd.io

log_message "DOCKER : ADD $USER to docker usergroup"
sudo usermod -a -G docker "$USER"
sudo usermod -a -G docker ubuntu

log_message "INSTALLATION OF microk8s channel 1.27/stable"
sudo snap install microk8s --classic --channel=1.27/stable

log_message "MICROK8S : ADD $USER to microk8s usergroup"
sudo usermod -a -G microk8s "$USER"
sudo usermod -a -G microk8s ubuntu
sudo chown -f -R "$USER" ~/.kube
sudo chown -f -R ubuntu /home/ubuntu/.kube

sudo usermod -a -G microk8s ubuntu
sudo chown -R ubuntu ~/.kube

log_message "MICROK8S waiting server to be ready"
sudo microk8s status --wait-ready

log_message "MICROK8S: enable dns registry and istio"
sudo microk8s enable dns
sudo microk8s enable registry
sudo microk8s enable community
sudo microk8s enable istio
sudo microk8s enable ingress

log_message "MICROK8S: configuring user session"
echo -e "\nalias kubectl='microk8s kubectl'" >> ~/.bash_aliases
echo -e "\nalias kubectl='microk8s kubectl'" >> /home/ubuntu/.bash_aliases
# shellcheck disable=SC1090
source ~/.bash_aliases
source /home/ubuntu/.bash_aliases

log_message "KUBECTL: Download and configure kubectl"
curl -LO "https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x ./kubectl
sudo mv ./kubectl /usr/local/bin/kubectl

log_message "MICROK8S: exporting kubeconfig file"
cd "$HOME"
mkdir -p .kube
echo "== generate the kubeconfig file"
sudo microk8s config | sudo tee .kube/config

echo "== remove excessive permissions on kubeconfig"
sudo chmod g-r "$HOME/.kube/config"
sudo chmod o-r "$HOME/.kube/config"
sudo chown $USER "$HOME/.kube/config"

log_message "MICROK8S: exporting kubeconfig file"
cd /home/ubuntu
mkdir -p .kube
echo "== generate the kubeconfig file"
sudo microk8s config | sudo tee .kube/config

echo "== remove excessive permissions on kubeconfig"
sudo chmod g-r "/home/ubuntu/.kube/config"
sudo chmod o-r "/home/ubuntu/.kube/config"
sudo chown ubuntu "/home/ubuntu/.kube/config"

sudo microk8s kubectl get nodes

newgrp docker
newgrp microk8s

# Install Helm
sudo snap install helm --classic

# Add Falcon to helm
log_message "HELM: Adding Falcon to Helm"
helm repo add crowdstrike https://crowdstrike.github.io/falcon-helm
helm repo update

# DOWNLOAD SWISS ARMY KNIFE
log_message "Sensor pull script: Downloading falcon-container-sensor-pull.sh"
curl -sSL -o falcon-container-sensor-pull.sh "https://raw.githubusercontent.com/CrowdStrike/falcon-scripts/main/bash/containers/falcon-container-sensor-pull/falcon-container-sensor-pull.sh"
chmod +x falcon-container-sensor-pull.sh

# INSTALL SENSOR
# - falcon-sensor (DaemonSet)
# - falcon-container (Sidecar)
log_message "Sensor install (DaemonSet): Installing falcon-sensor"
export SENSOR_TYPE=falcon-sensor

export FALCON_IMAGE_TAG=$(./falcon-container-sensor-pull.sh -u $FALCON_CLIENT_ID -s $FALCON_CLIENT_SECRET --list-tags -t falcon-sensor | jq -r '.tags[-1]')
export FALCON_IMAGE_REPO="registry.crowdstrike.com/${SENSOR_TYPE}/${FALCON_CLOUD}/release/${SENSOR_TYPE}"

OUTPUT=$(./falcon-container-sensor-pull.sh -u $FALCON_CLIENT_ID -s $FALCON_CLIENT_SECRET --dump-credentials)
FALCON_ART_USERNAME=$(echo "$OUTPUT" | grep Username | awk '{ print $3 }')
FALCON_ART_PASSWORD=$(echo "$OUTPUT" | grep Password | awk '{ print $3 }')

export PARTIALPULLTOKEN=$(echo -n "$FALCON_ART_USERNAME:$FALCON_ART_PASSWORD" | base64 -w 0)
export FALCON_IMAGE_PULL_TOKEN=$(echo "{\"auths\":{\"registry.crowdstrike.com\":{\"auth\":\"$PARTIALPULLTOKEN\"}}}" | base64 -w 0)

NEW_TAG="Type/DaemonSet"
NEW_TAGS="$FALCON_TAGS,$NEW_TAG"

helm upgrade --install falcon-helm crowdstrike/falcon-sensor \
    -n falcon-system --create-namespace \
    --set falcon.cid=$FALCON_CID \
    --set falcon.tags=${NEW_TAGS//,/\\,} \
    --set node.backend=bpf \
    --set node.image.registryConfigJSON=$FALCON_IMAGE_PULL_TOKEN \
    --set node.image.tag=$FALCON_IMAGE_TAG \
    --set node.image.repository=$FALCON_IMAGE_REPO

NAME=$(microk8s kubectl get pods -n falcon-system | grep 'falcon-helm-falcon-sensor-' | awk '{ print $1 }')
if microk8s kubectl wait --for=condition=Ready pod/$NAME --namespace falcon-system --timeout=120s; then
  echo "Pod ($NAME) has deployed successfully."
else
  echo "Pod ($NAME) deployment failed or timed out."
fi

microk8s kubectl exec $NAME -n falcon-system -- /opt/CrowdStrike/falconctl -g --aid --version --backend --rfm-state

# INSTALL KPA (Kubernetes Protection Agent)
log_message "INSTALL KPA (Kubernetes Protection Agent)"

cat >~/config_value.yaml <<EOL
image:
  repository: registry.crowdstrike.com/kubernetes_protection/kpagent
  tag: 0.1854.0
crowdstrikeConfig:
  clientID: "$FALCON_CLIENT_ID"
  clientSecret: "$FALCON_CLIENT_SECRET"
  clusterName: $(hostname)
  env: $FALCON_CLOUD
  cid: ${FALCON_CID::-3}
  dockerAPIToken: $FALCON_DOCKER_TOKEN

EOL

helm repo add kpagent-helm https://registry.crowdstrike.com/kpagent-helm
helm repo update

helm upgrade --install -f ~/config_value.yaml --create-namespace -n falcon-kubernetes-protection kpagent kpagent-helm/cs-k8s-protection-agent

NAME=$(microk8s kubectl get pods -n falcon-kubernetes-protection | grep 'kpagent-cs-k8s-protection-agent-' | awk '{ print $1 }')
if microk8s kubectl wait --for=condition=Ready pod/$NAME --namespace falcon-kubernetes-protection --timeout=120s; then
  echo "Pod ($NAME) has deployed successfully."
else
  echo "Pod ($NAME) deployment failed or timed out."
fi

# INSTALL KAC (Kubernetes Admission Controller)
log_message "INSTALL KAC (Kubernetes Admission Controller)"
export SENSOR_TYPE=falcon-kac

export FALCON_IMAGE_TAG=$(./falcon-container-sensor-pull.sh -u $FALCON_CLIENT_ID -s $FALCON_CLIENT_SECRET --list-tags | jq -r '.tags[-1]')
export FALCON_IMAGE_REPO="registry.crowdstrike.com/${SENSOR_TYPE}/${FALCON_CLOUD}/release/${SENSOR_TYPE}"

OUTPUT=$(./falcon-container-sensor-pull.sh -u $FALCON_CLIENT_ID -s $FALCON_CLIENT_SECRET --kubernetes-admission-controller --dump-credentials)
FALCON_ART_USERNAME=$(echo "$OUTPUT" | grep Username | awk '{ print $3 }')
FALCON_ART_PASSWORD=$(echo "$OUTPUT" | grep Password | awk '{ print $3 }')

export PARTIALPULLTOKEN=$(echo -n "$FALCON_ART_USERNAME:$FALCON_ART_PASSWORD" | base64 -w 0)
export FALCON_IMAGE_PULL_TOKEN=$(echo "{\"auths\":{\"registry.crowdstrike.com\":{\"auth\":\"$PARTIALPULLTOKEN\"}}}" | base64 -w 0)

sudo chown ubuntu:ubuntu -R /home/ubuntu/

NEW_TAG="Type/KAC"
NEW_TAGS="$FALCON_TAGS,$NEW_TAG"

helm --kubeconfig /home/ubuntu/.kube/config upgrade --install falcon-kac crowdstrike/falcon-kac \
   -n falcon-kac --create-namespace \
  --set falcon.cid=$FALCON_CID \
  --set falcon.tags=${NEW_TAGS//,/\\,} \
  --set image.registryConfigJSON=$FALCON_IMAGE_PULL_TOKEN \
  --set image.tag=$FALCON_IMAGE_TAG \
  --set image.repository=$FALCON_IMAGE_REPO

microk8s kubectl get pods -n falcon-kac
NAME=$(microk8s kubectl get pods -n falcon-kac | grep 'falcon-kac-' | awk '{ print $1 }')
if microk8s kubectl wait --for=condition=Ready pod/$NAME --namespace falcon-kac --timeout=120s; then
  echo "Pod ($NAME) has deployed successfully."
else
  echo "Pod ($NAME) deployment failed or timed out."
fi

microk8s kubectl exec deployment/falcon-kac -n falcon-kac -c falcon-ac -- falconctl -g --aid

microk8s kubectl patch -n falcon-kac cm falcon-kac-meta -p '{ "data": { "ClusterName": "'$ENV_ALIAS'-kube" } }'
microk8s kubectl rollout restart -n falcon-kac deployment falcon-kac

cat > /home/ubuntu/iar-install.txt <<EOL
# INSTALL IAR
export FALCON_CLIENT_ID="MY_API_SKEY"
export FALCON_CLIENT_SECRET="MY_API_SECRET"
export FALCON_CLOUD_ENV=us-2  #change for other clouds
export FALCON_CID=$( ./falcon-container-sensor-pull.sh -t falcon-imageanalyzer --get-cid )
export FALCON_IMAGE_FULL_PATH=$( ./falcon-container-sensor-pull.sh -t falcon-imageanalyzer --get-image-path )
export FALCON_IMAGE_REPO=$( echo $FALCON_IMAGE_FULL_PATH | cut -d':' -f 1 )
export FALCON_IMAGE_TAG=$( echo $FALCON_IMAGE_FULL_PATH | cut -d':' -f 2 )
export FALCON_IMAGE_PULL_TOKEN=$( ./falcon-container-sensor-pull.sh -t falcon-imageanalyzer --get-pull-token )
export FALCON_IAR_CLUSTER_NAME=$(kubectl config view -o json | jq -r ".clusters[0].name")

helm repo add crowdstrike https://crowdstrike.github.io/falcon-helm --force-update
helm upgrade --install iar crowdstrike/falcon-image-analyzer \
  -n falcon-image-analyzer --create-namespace \
  --set deployment.enabled=true \
  --set crowdstrikeConfig.cid="$FALCON_CID" \
  --set crowdstrikeConfig.clusterName="$FALCON_IAR_CLUSTER_NAME" \
  --set crowdstrikeConfig.clientID=$FALCON_CLIENT_ID \
  --set crowdstrikeConfig.clientSecret=$FALCON_CLIENT_SECRET \
  --set crowdstrikeConfig.agentRegion=$FALCON_CLOUD_ENV \
  --set image.registryConfigJSON=$FALCON_IMAGE_PULL_TOKEN \
  --set image.repository="$FALCON_IMAGE_REPO" \
  --set image.tag="$FALCON_IMAGE_TAG"
EOL

#####################################
# deploy vulnerable container

log_message "deploy vulnerable container"

curl http://localhost:32000/v2/_catalog?n=10

mkdir testimage
cat >testimage/Dockerfile <<EOL
FROM ubuntu:16.04
RUN apt-get -yqq update
EOL

docker build testimage/ -t localhost:32000/testimage:latest
IMAGE_ID=$(docker images | grep testimage | awk '{ print $3 }')
echo $IMAGE_ID
curl http://localhost:32000/v2/_catalog?n=10

docker tag $IMAGE_ID localhost:32000/testimage:latest
docker push localhost:32000/testimage
curl http://localhost:32000/v2/_catalog?n=10

mkdir ~/tomcat_container
cd ~/tomcat_container
cat >Dockerfile <<EOL
FROM ubuntu:16.04

# Install Apache
RUN apt-get -yqq update
RUN apt-get -yqq install openjdk-8-jdk wget net-tools awscli
RUN mkdir /opt/tomcat \
&& cd /opt/tomcat \
&& wget -q "URL_TO_TOMCAT_ARCHIVE" -O apache-tomcat-8.0.32.tar.gz \
&& wget -q "URL_TO_TEDS_WEB_XML" -O teds-web.xml \
&& tar zxvf apache-tomcat-8.0.32.tar.gz \
&& cp teds-web.xml /opt/tomcat/apache-tomcat-8.0.32/conf/web.xml \
&& echo "export JAVA_HOME=/usr/lib/jvm/java-1.8.0-openjdk-amd64" >> ~/.bashrc \
&& echo "export CATALINA_HOME=/opt/tomcat/apache-tomcat-8.0.32" >> ~/.bashrc

CMD ["/opt/tomcat/apache-tomcat-8.0.32/bin/catalina.sh", "run"]

EXPOSE 8080
EOL

docker build . -t localhost:32000/tomcat-webshell:latest
IMAGE_ID=$(docker images | grep tomcat-webshell | awk '{ print $3 }')
echo $IMAGE_ID

docker tag $IMAGE_ID localhost:32000/tomcat-webshell:latest
docker push localhost:32000/tomcat-webshell

docker login --username ${FALCON_CLIENT_ID} --password ${FALCON_CLIENT_SECRET} container-upload.$FALCON_CLOUD.crowdstrike.com
docker tag localhost:32000/tomcat-webshell:latest container-upload.$FALCON_CLOUD.crowdstrike.com/tomcat-webshell:$ENV_ALIAS
docker push container-upload.$FALCON_CLOUD.crowdstrike.com/tomcat-webshell:$ENV_ALIAS

cat >tomcat.example.yaml <<EOL
# kubectl apply -f ~/.aws/share/tomcat.example.yaml
# kubectl get service tomcat-example-com
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tomcat.example.com
  labels:
    app.kubernetes.io/name: tomcat.example.com
    app.kubernetes.io/part-of: crowdstrike-demo
    app.kubernetes.io/created-by: crowdstrike
spec:
  selector:
    matchLabels:
      run: tomcat.example.com
  replicas: 1
  template:
    metadata:
      labels:
        run: tomcat.example.com
        app.kubernetes.io/name: tomcat.example.com
        app.kubernetes.io/part-of: crowdstrike-demo
        app.kubernetes.io/created-by: crowdstrike
      annotations:
        sensor.falcon-system.crowdstrike.com/injection: enabled
    spec:
      containers:
        - name: tomcat-webshell
          image: localhost:32000/tomcat-webshell
          imagePullPolicy: Always
          command:
            - "/opt/tomcat/apache-tomcat-8.0.32/bin/catalina.sh"
          args:
            - "run"
          ports:
            - containerPort: 8080
              name: web

---
apiVersion: v1
kind: Service
metadata:
  name: tomcat-example-com
  labels:
    app.kubernetes.io/name: tomcat-example-com
    app.kubernetes.io/part-of: crowdstrike-demo
    app.kubernetes.io/created-by: crowdstrike
spec:
  selector:
    run: tomcat.example.com
  ports:
    - port: 8082
      targetPort: 8080
      nodePort: 30007
  type: LoadBalancer

---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: tomcat-example-com-ingress
spec:
  rules:
    - host: tomcat.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: tomcat-example-com
                port:
                  number: 8082
EOL

microk8s kubectl apply -f tomcat.example.yaml
microk8s kubectl get service tomcat-example-com

microk8s kubectl get pods
NAME=$(microk8s kubectl get pods | grep 'tomcat' | awk '{ print $1 }')
microk8s kubectl logs $NAME

microk8s kubectl get service

# Install tools for Cloud IOA

wget -q "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -O "awscliv2.zip"
unzip -qq -o awscliv2.zip
sudo ./aws/install
echo "AWS Version:"
aws --version

AWS_CURL=/usr/local/bin/aws-curl
if [ ! -f "$AWS_CURL" ]; then
  echo "$AWS_CURL does not exist. Downloading..."
  sudo curl -s https://raw.githubusercontent.com/sormy/aws-curl/master/aws-curl -o /usr/local/bin/aws-curl
  sudo chmod 777 /usr/local/bin/aws-curl
fi

mkdir -p /home/ubuntu/detections/cloud/{ioa,iom,images,container}

cat >/home/ubuntu/detections/cloud/ioa/behavioral-ioa.sh <<'EOL'
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
ROLE_NAME=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/iam/security-credentials/)
EC2_AVAIL_ZONE=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)
AWS_DEFAULT_REGION=$(echo "$EC2_AVAIL_ZONE" | sed 's/[a-z]$//')
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
AWS_ACCESS_KEY_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/iam/security-credentials/$ROLE_NAME | jq -r .AccessKeyId)
AWS_SECRET_ACCESS_KEY=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/iam/security-credentials/$ROLE_NAME | jq -r .SecretAccessKey)
AWS_SESSION_TOKEN=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/iam/security-credentials/$ROLE_NAME | jq -r .Token)

export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_SESSION_TOKEN

/usr/local/bin/aws-curl -s --request POST \
  --header "Content-Type: application/x-www-form-urlencoded" \
  --header "User-Agent: \${jndi:exploit}" \
  --data "Version=2016-11-15" \
  --data "Action=CreateTags" \
  --data "ResourceId.1=$INSTANCE_ID" \
  --data "Tag.1.Key=Name" \
  --data "Tag.1.Value=NewInstanceName" \
  --region "us-west-2" \
  "https://ec2.us-west-2.amazonaws.com/"

echo
echo "YOU CAN IGNORE ANY ERRORS ABOVE"
echo
echo "$(date) - You should now see a detection for \"A user agent using JNDI injection (Log4Shell) exploits seen by AWS CloudTrail\" triggered by $ROLE_NAME"
echo
EOL
sudo dos2unix /home/ubuntu/detections/cloud/ioa/behavioral-ioa.sh
chown ubuntu:ubuntu /home/ubuntu/detections/cloud/ioa/behavioral-ioa.sh
chmod +x /home/ubuntu/detections/cloud/ioa/behavioral-ioa.sh

cat >/home/ubuntu/detections/cloud/ioa/disable-bucket-logging-ioa.sh <<'EOL'
echo "Will begin to generate the Cloud IOA for disabling bucket logging"
LAB_S3_BUCKET=$(aws s3api list-buckets --query "Buckets[? contains(Name,'$ENV_ALIAS-')]" | jq -r '.[0].Name')

echo "Your bucket is $LAB_S3_BUCKET"
aws s3api list-buckets --query "Buckets[? contains(Name,'$ENV_ALIAS-')]"
echo "Fetching the logging policy for $LAB_S3_BUCKET"
aws s3api get-bucket-logging --bucket $LAB_S3_BUCKET
echo "{}" > no-bucket-logging.json
echo "Disabling the logging policy for $LAB_S3_BUCKET"
aws s3api put-bucket-logging --bucket $LAB_S3_BUCKET --bucket-logging-status file://no-bucket-logging.json
echo "Listing the contents in $LAB_S3_BUCKET"
aws s3 ls s3://$LAB_S3_BUCKET
echo "Stealing files from $LAB_S3_BUCKET"
aws s3 cp s3://$LAB_S3_BUCKET/confidential-data.txt stolen-info.txt
ls
cat stolen-info.txt

echo
echo
echo "$(date) - You should now see a detection for \"S3 bucket access logging disabled\" triggered by ${ENV_ALIAS}-ec2-role-XXXXXX"
echo
EOL
sudo dos2unix /home/ubuntu/detections/cloud/ioa/disable-bucket-logging-ioa.sh
chown ubuntu:ubuntu /home/ubuntu/detections/cloud/ioa/disable-bucket-logging-ioa.sh
chmod +x /home/ubuntu/detections/cloud/ioa/disable-bucket-logging-ioa.sh

cat >/home/ubuntu/detections/cloud/container/runtime-detections.sh <<'EOL'
USER=$LOGNAME

if [ -x "$(command -v docker)" ]; then
  echo "Docker is installed"
else
  echo "Docker is NOT installed"
  
  # update the ubuntu config to not popup service to update
  echo "======= configuring ubuntu to not generate any popup during update ======="
  sudo sed -i "/#\$nrconf{restart} = 'i';/s/.*/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf

  sudo apt-get update && sudo apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    jq \
    lsb-release

  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

  echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  sudo apt-get update && sudo apt-get install -y docker-ce docker-ce-cli containerd.io
  
  newgrp docker
fi

date
cd ~
# Populate "Privilege and Out-of-Memory" counter
docker rm ubuntu_server
docker run --privileged --oom-kill-disable --name ubuntu_server -P -d ubuntu

# Populate "Interactive Mode" counter
# Check if SSH key exists
if [ ! -f ~/.ssh/self.key ]; then
  ssh-keygen -t rsa -b 4096 -C "SSH to self" -f ~/.ssh/self.key -N ""
  cat ~/.ssh/self.key.pub >> ~/.ssh/authorized_keys
fi
docker rm debian_server
ssh -i ~/.ssh/self.key -o StrictHostKeyChecking=no -tt $USER@127.0.0.1 'docker run -it debian /bin/bash -c "whoami" --name debian_server'

echo
echo
echo
echo "Hopefully you should now have container detections!"
echo
EOL
sudo dos2unix /home/ubuntu/detections/cloud/container/runtime-detections.sh
chown ubuntu:ubuntu /home/ubuntu/detections/cloud/container/runtime-detections.sh
chmod +x /home/ubuntu/detections/cloud/container/runtime-detections.sh

sudo chown ubuntu:ubuntu -R /home/ubuntu/

