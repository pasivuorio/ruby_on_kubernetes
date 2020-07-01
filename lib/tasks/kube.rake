require 'dotenv/tasks'

Rake.application.options.trace = false

Dotenv.load('.env.production.cluster')

IP_ADDR_REGEX = %r{
      (?<=\s|^)
      (25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.
      (25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.
      (25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.
      (25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)
      (?=\s|$)
    }x

def store_env(key, val)
  #arrays are not supposed to be envs
  return if val.is_a?(Array)

  #support levels, call this recursively
  if val.is_a?(Hash)
    val.each do |key2, val2|
      store_env([key, key2].join('_'), val2)
    end
  else
    ENV[key.upcase] = val.to_s
  end
end

#read applications setup
file = IO.read(File.join(Rails.root, "config/cluster.yml"))
#parse Yaml & ERB
@cluster_settings = YAML.load(ERB.new(file).result)
#read as env variables so they are usable from .yaml files
@cluster_settings.each do |key, val|
  store_env(key, val)
end


#read applications setup
file = IO.read(File.join(Rails.root, "config/applications.yml"))
#parse Yaml & ERB
@app_settings = YAML.load(ERB.new(file).result)

port = 2500 #start with port 3000 and increase by 500
@app_settings.each do |app, settings|
  unless settings['no_app_server']
    ENV["#{app.to_s.upcase}_INTERNAL"] = "http://#{app.to_s}-service:#{port+=500}"
    puts "#{app.to_s.upcase}_INTERNAL = #{ENV["#{app.to_s.upcase}_INTERNAL"]}"
  end
end
#reload to add internal links
@app_settings = YAML.load(ERB.new(file).result)

namespace :kube do
  namespace :cluster do

    desc 'Apply our Kubernete configurations to our cluster'
    task :setup do

      cluster = DropletKit::KubernetesCluster.new(@cluster_settings['cluster'])

      cluster = do_client.kubernetes_clusters.create(cluster) rescue nil
      cluster_created = true if cluster

      if cluster_created
        puts "Cluster created, wait until cluster is fully initialized and enter 'y' to continue"
        sleep(2.seconds)
        system "open https://cloud.digitalocean.com/kubernetes/clusters"
        input = STDIN.gets.strip

        while input != 'y'
          STDOUT.puts "wait until cluster is fully initialized and press 'y' and enter to continue"
          input = STDIN.gets.strip
        end
      end
      #connect to digital ocean cluster and load credentials
      doctl "kubernetes cluster kubeconfig save #{ENV['CLUSTER_NAME']}"

      # Add our Docker Hub credentials to our cluster
      kubectl(%Q{create secret docker-registry regcred \
        --docker-server=#{ENV['DOCKER_REGISTRY_SERVER']} \
        --docker-username=#{ENV['DOCKER_USERNAME']} \
        --docker-password=#{ENV['DOCKER_PASSWORD']} \
        --docker-email=#{ENV['DOCKER_EMAIL']} || true
     })

      # Install cert-manager
      kubectl 'create namespace cert-manager'

      # Add the Digital Ocean token to the cluster
      ENV['DIGITAL_OCEAN_TOKEN_BASE64'] = Base64.strict_encode64(ENV["DIGITAL_OCEAN_TOKEN"])
      apply "kube/dns_cert/secret-digital-ocean.yml"

      # Add the Digital Ocean spaces (aws s3 compatible) credentials
      ENV['AWS_SECRET_ACCESS_KEY_BASE64'] = Base64.strict_encode64(ENV["AWS_SECRET_ACCESS_KEY"])
      ENV['AWS_ACCESS_KEY_ID_BASE64'] = Base64.strict_encode64(ENV["AWS_ACCESS_KEY_ID"])
      ENV['AWS_S3_REGION_BASE64'] = Base64.strict_encode64(ENV["AWS_S3_REGION"])
      ENV['AWS_ENDPOINT_URL_BASE64'] = Base64.strict_encode64(ENV["AWS_ENDPOINT_URL"])

      apply "kube/aws_secrets.yml"

      s3 = Aws::S3::Client.new(http_wire_trace: true, access_key_id: ENV["AWS_ACCESS_KEY_ID"], secret_access_key: ENV["AWS_SECRET_ACCESS_KEY"],
                               endpoint: ENV["AWS_ENDPOINT_URL"], region: "us-east-1",signature_version: 'v4')

      #create S3 compatible bucket with cluster name
      s3.create_bucket(bucket: "#{ENV['CLUSTER_NAME']}-apps") rescue nil
      s3.create_bucket(bucket: "#{ENV['CLUSTER_NAME']}-backups") rescue nil

      # Add a digital ocean load balancer types
      apply "kube/dns_cert/do-ingress.yaml"

      # Certmanager for obtaining letsencrypt
      apply "https://github.com/jetstack/cert-manager/releases/download/v0.15.1/cert-manager.yaml"

      if cluster_created
        puts "Cluster created, wait until load balancer is up and enter 'y' to continue"
        sleep(2.seconds)
        system "open https://cloud.digitalocean.com/networking/load_balancers"
        input = STDIN.gets.strip

        while input != 'y'
          STDOUT.puts "wait until load balancer is up and press 'y' and enter to continue"
          input = STDIN.gets.strip
        end
      end

    end

    task :delete_cert do
      # Certmanager for obtaining letsencrypt
      delete "https://github.com/jetstack/cert-manager/releases/download/v0.15.1/cert-manager.yaml"
      # Add a digital ocean load balancer types
      delete "kube/dns_cert/do-ingress.yaml"
    end

    task :backup_certs do

      Dir.chdir(File.join(Rails.root, "kube"))

      kubectl "get -o yaml --all-namespaces issuer,clusterissuer,certificates,certificaterequests > cert-manager-backup.yaml"

      s3 = Aws::S3::Resource.new(http_wire_trace: true, access_key_id: ENV["AWS_ACCESS_KEY_ID"], secret_access_key: ENV["AWS_SECRET_ACCESS_KEY"],
                               endpoint: ENV["AWS_ENDPOINT_URL"], region: "us-east-1", signature_version: 'v4')

      # Create the object to upload
      obj = s3.bucket("#{ENV['CLUSTER_NAME']}-backups").object('cert-manager-backup.yaml')
      # Upload it
      obj.upload_file(File.join(Rails.root, "kube/cert-manager-backup.yaml"))
    end

    task :restore_certs do
      s3 = Aws::S3::Resource.new(http_wire_trace: true, access_key_id: ENV["AWS_ACCESS_KEY_ID"], secret_access_key: ENV["AWS_SECRET_ACCESS_KEY"],
                                 endpoint: ENV["AWS_ENDPOINT_URL"], region: "us-east-1", signature_version: 'v4')
      # Create the object to upload
      obj = s3.bucket("#{ENV['CLUSTER_NAME']}-backups").object('cert-manager-backup.yaml')

      # Get the item's content and save it to a file
      obj.get(response_target: File.join(Rails.root, "kube/cert-manager-backup.yaml"))

      apply File.join(Rails.root, "kube/cert-manager-backup.yaml")
    end

    task :wait_finished do
      wait_loop
    end

    desc 'Build all repos linked in this cluster'
    task :build_all => (%w[kube:db:build kube:redis:build])
    desc 'Setup cluster and databases'
    task :setup_all => (%w[kube:cluster:setup kube:monitoring:setup kube:db:setup kube:redis:setup])
  end
  # monitoring does not work yet
  # namespace :monitoring do
  #   task :setup do
  #   #go to parent folder
  #   Dir.chdir(Rails.root)
  #
  #   ENV["APP_INSTANCE_NAME"]=ENV['CLUSTER_NAME']
  #   ENV["NAMESPACE"]="default"
  #   ENV['GRAFANA_PASSWORD_BASE64'] = Base64.strict_encode64(ENV["GRAFANA_PASSWORD"])
  #   ENV["GRAFANA_GENERATED_PASSWORD"]= ENV['GRAFANA_PASSWORD_BASE64']
  #
  #   Dir.chdir("kube")
  #
  #   print %x{ awk 'FNR==1 {print "---"}{print}' monitoring/* \
  #         | envsubst '$APP_INSTANCE_NAME $NAMESPACE $GRAFANA_GENERATED_PASSWORD' \
  #         > "${APP_INSTANCE_NAME}_monitoring.yaml"}
  #
  #   apply "kube/woolman_monitoring.yaml"
  #
  #   register_domain("grafana-ingress", ENV['MONITORING_GRAFANA_URL'])
  #   # Add the certificate issuer (this must be done after first ingress and DNS is ready)
  #   apply "kube/dns_cert/cluster-issuer.yml"
  #
  #   #settings for certificate
  #   ENV['DNS_WEBSITE'] = ENV['MONITORING_GRAFANA_URL']
  #   ENV['APP_NAME'] = "grafana"
  #
  #   # Add our certificate
  #   apply "kube/dns_cert/certificate.yml"
  # end
  # end

  namespace :db do
    desc 'Build database docker image and push to registry'
    task :build do
      Dir.chdir "kube/stolon/docker"

      system "docker build -t #{ENV['DOCKER_USERNAME']}/stolon:latest .
            docker push #{ENV['DOCKER_USERNAME']}/stolon:latest"
    end

    desc 'Initialize database (rake:db:setup[restore] or rake:db:setup[new])'
    task :setup, :init do |task, args|

      args.with_defaults(:init => false)

      #stolon postgres initializing
      apply "kube/stolon/role.yaml"
      apply "kube/stolon/role-binding.yaml"
      ENV['STOLON_PASSWORD_BASE64'] = Base64.strict_encode64(ENV["STOLON_PASSWORD"])
      apply "kube/stolon/secret.yaml"

      if args[:init] == "restore"
        wait_loop(5.seconds, "wait until stolon initialized")
        kubectl "run -i -t stolonctl --image=#{ENV['DOCKER_USERNAME']}/stolon:latest --restart=Never --rm -- /usr/local/bin/stolonctl --cluster-name=kube-stolon --store-backend=kubernetes --kube-resource-kind=configmap init -y '{ \"initMode\": \"pitr\", \"pitrConfig\": { \"dataRestoreCommand\": \"backup.sh backup-fetch %d LATEST\" , \"archiveRecoverySettings\": { \"restoreCommand\": \"backup.sh wal-fetch %f %p\" } } }'"
      elsif args[:init] == "new"
        wait_loop(5.seconds, "wait until stolon initialized")
        kubectl "run -i -t stolonctl --image=#{ENV['DOCKER_USERNAME']}/stolon:latest --restart=Never --rm -- /usr/local/bin/stolonctl --cluster-name=kube-stolon --store-backend=kubernetes --kube-resource-kind=configmap init -y"
      end

      apply "kube/stolon/volume-definitions.yml"
      apply "kube/stolon/stolon-sentinel.yaml"
      apply "kube/stolon/stolon-keeper.yaml"
      apply "kube/stolon/stolon-proxy.yaml"
      apply "kube/stolon/stolon-proxy-service.yaml"

      wait_loop(20.seconds, "wait until stolon services start")

      #set database backup settings
      system "kubectl exec -it #{find_first_pod_name('stolon-keeper')} -- stolonctl --cluster-name=kube-stolon --store-backend=kubernetes --kube-resource-kind=configmap update --patch '{ \"pgParameters\" : { \"archive_mode\": \"on\",  \"archive_timeout \": \"1h\", \"archive_command\": \"backup.sh wal-push %p\" } }'"
    end

    desc "Restart database hosts"
    task :restart do
      kubectl "rollout restart statefulset stolon-keeper"
    end

    desc 'Restore database'
    task :restore do
      #set archive mode off and standby mode on
      #system "kubectl exec -it #{find_first_pod_name('stolon-keeper')} -- stolonctl --cluster-name=kube-stolon --store-backend=kubernetes --kube-resource-kind=configmap update --patch '{ \"pgParameters\" : { \"archive_mode\": \"off\",  \"standby_mode \": \"on\"} }'"

      #download latest backup & initiate wal fetching
      system "kubectl exec -it #{find_first_pod_name('stolon-keeper')} -- stolonctl init '{ \"initMode\": \"pitr\", \"pitrConfig\": { \"dataRestoreCommand\": \"backup.sh backup-fetch %d LATEST\" , \"archiveRecoverySettings\": { \"restoreCommand\": \"backup.sh wal-fetch \"%f\" \"%p\"\" } } }'"
    end

    task :backup do
      system "kubectl exec -it #{find_first_pod_name('stolon-keeper')} -- backup.sh backup-push /stolon-data/"
    end

    task :shell do
      system "kubectl exec -it #{find_first_pod_name('stolon-keeper')} /bin/bash"
    end

    desc 'Delete database'
    task :delete do
      delete "kube/stolon/stolon-proxy-service.yaml"
      delete "kube/stolon/stolon-proxy.yaml"
      delete "kube/stolon/stolon-keeper.yaml"
      delete "kube/stolon/stolon-sentinel.yaml"
        #delete "kube/stolon/volume-definitions.yml"
    end

    task :port_forward do
      exec "kubectl port-forward service/stolon-proxy-service 5432"
    end
  end

  namespace :elastic do
    desc 'Deploy elasticsearch'
    task :setup do
      apply "kube/elastic/all-in-one.yaml"
      apply "kube/elastic/local_storage_volumes.yml"
      apply "kube/elastic/elasticsearch.yml"
      wait_loop(15.seconds, "wait until ES is initialized")
      apply "kube/elastic/kibana.yml"
      apply "kube/elastic/es-apm.yml"
      apply "kube/elastic/filebeat.yml"
      apply "kube/elastic/ingress.yml"

      register_domain("kibana-ingress", ENV['ELASTIC_KIBANA_URL'])
      # Add the certificate issuer (this must be done after first ingress and DNS is ready)
      apply "kube/dns_cert/cluster-issuer.yml"

      #settings for certificate
      ENV['DNS_WEBSITE'] = ENV['ELASTIC_KIBANA_URL']
      ENV['APP_NAME'] = "kibana"

      # Add our certificate
      apply "kube/dns_cert/certificate.yml"
    end

    task :delete do
      #settings for certificate
      ENV['DNS_WEBSITE'] = ENV['ELASTIC_KIBANA_URL']
      ENV['APP_NAME'] = "kibana"

      delete "kube/dns_cert/certificate.yml"
      delete "kube/dns_cert/cluster-issuer.yml"
      delete "kube/elastic/ingress.yml"
      delete "kube/elastic/kibana.yml"
      delete "kube/elastic/es-apm.yml"
      delete "kube/elastic/filebeat.yml"
      delete "kube/elastic/elasticsearch.yml"
      delete "kube/elastic/local_storage_volumes.yml"
      delete "kube/elastic/all-in-one.yaml"
    end

    task :port_forward do
      exec "kubectl port-forward service/elasticsearch-es-http 9200"
    end
  end

  namespace :redis do
    desc 'Build redis image and deploy'
    task :build do
      Dir.chdir "#{Rails.root}/kube/redis/docker"

      system "docker build -t #{ENV['DOCKER_USERNAME']}/redis:latest .
            docker push #{ENV['DOCKER_USERNAME']}/redis:latest"
    end

    desc 'Deploy redis'
    task :setup do
      ENV['REDIS_PASSWORD_BASE64'] = Base64.strict_encode64(ENV["REDIS_PASSWORD"])
      ENV['REDIS_URL_BASE64'] = Base64.strict_encode64("redis://:#{ENV["REDIS_PASSWORD"]}@redis-ha-cluster-startup-redis-master-service:6379")
      apply "kube/redis/secret.yaml"
      apply "kube/redis/create-service.yaml"
      apply "kube/redis/create-master-deployment.yaml"
      apply "kube/redis/create-sentinel-deployment.yaml"
      apply "kube/redis/create-slave-deployment.yaml"
    end
  end

  namespace :apps do
    desc 'Build all app repos linked in this cluster'
    task :build_all =>  @app_settings.map{|app, settings| "kube:#{app}:build"}
    desc 'Setup all app settings'
    task :setup_all => @app_settings.map{|app, settings| "kube:#{app}:setup"}
    desc 'Deploy everything'
    task :deploy_all => @app_settings.map{|app, settings| "kube:#{app}:deploy"}
  end

  port = 2500 #start with port 3000 and increase by 500
  @app_settings.each do |app, settings|
    namespace app.to_sym do

      desc 'Build application dockerfile'
      task :build do
        puts "building #{app} with settings: #{settings}"

        #go to build directory
        Dir.chdir(File.expand_path("build", Rails.root))

        #remove directory if exist
        system "rm -rf #{settings['path']}" if Dir.exist?(settings['path'])

        #clone the repository and correct branch
        system "git clone --branch #{settings['git_branch']} #{settings['git_repo']}"

        #go to app directory
        Dir.chdir(settings['path'])

        build_variables = []
        #build rails docker file in this repository
        unless settings['own_docker_file']

          #copy dockerfile from this repository to app directory, we'll use this in compile
          FileUtils.cp(File.join(Rails.root, "Dockerfile"),'./Dockerfile')

          #copy docker entrypoint from this repo to app bin folder
          FileUtils.cp(File.join(Rails.root, "bin/entrypoint.sh"), 'bin/')

          #copy database.yml from this repo to app repo as database.yml (this replaces own database.yml )
          FileUtils.cp(File.join(Rails.root, "config/database.yml"), "./config/database.yml")

          #copy elasticsearch.yml from this repo to app repo as elasticsearch.yml (this replaces own database.yml )
          FileUtils.cp(File.join(Rails.root, "config/elasticsearch.yml"), "./config/elasticsearch.yml")

          FileUtils.cp(File.join(Rails.root, "config/initializers/x_kube_elasticsearch_init.rb"), "./config/initializers/")

          build_variables =
              {"RAILS_ENV":"production",
               "NODE_ENV":"production",
               "RUBY_VERSION":settings['ruby_version'],
               "NODE_VERSION":settings['node_version'],
               "RAILS_MASTER_KEY":settings['rails_master_key'],
               "PORT": (port+=500).to_s}

          if settings['reset_credentials']

            #remove encrypted credentials and create empty in Docker comple
            build_variables['RESET_CREDENTIALS'] = true
            config_dir = File.join(Dir.pwd(), 'config')
            puts "reset credentials #{config_dir}"
            Dir.glob(config_dir + "/*").select{ |file| /.yml.enc/.match file }.each { |file| File.delete(file)}
          end
        else
          #build external docker file
          build_variables = settings['docker_build_args'].first
        end

        #run docker build, push it to repository and restore dockerfile if needed
        system "docker build #{build_variables.map{|key, val| "--build-arg #{key}=\"#{val}\""}.join(' ')} -t #{ENV['DOCKER_USERNAME']}/#{app}:latest .
              docker push #{ENV['DOCKER_USERNAME']}/#{app}:latest"

        #go to build directory
        Dir.chdir(File.expand_path("build", Rails.root))

        #remove build directory
        system "rm -rf #{settings['path']}" if Dir.exist?(settings['path'])
      end

      desc "setup application (load settings)"
      task :setup do
        ENV['APP_NAME'] = app.to_s

        all_settings = settings['environment']

        #rails master key is set in environment unless it is not used
        all_settings.merge!({'RAILS_MASTER_KEY'=>settings['rails_master_key']}) unless settings['reset_credentials']

        config_yaml = {
            'apiVersion'=>'v1',
            'kind'=>'ConfigMap',
            'metadata'=> {
              'name'=> "#{app.to_s}-config",
              'namespace'=> 'default',
            },
            'data' =>  all_settings
        }

        puts config_yaml.to_yaml
        Dir.chdir(Rails.root)
        filename = "#{app.to_s}_configmap.yml"
        File.open(filename, 'w') {|f| f.write config_yaml.to_yaml } #Store
        apply(filename)
      end

      desc 'Rollout a new deployment'
      task :deploy do
        ENV['APP_NAME'] = app.to_s
        ENV['DNS_WEBSITE'] = settings['domain']
        ENV['RAILS_ENV'] = "production"

        unless settings['no_app_server']
          ENV['APP_PORT'] = settings['port']&.to_s || (port+=500).to_s
          ENV['APP_TIER'] = settings['deploy_tier']
          ENV['APP_CPU_LIMIT'] = settings['cpu_limit'].to_s
          ENV['APP_MEM_LIMIT'] = settings['mem_limit']
          ENV['APP_CPU_REQUEST'] = settings['cpu_request'].to_s
          ENV['APP_MEM_REQUEST'] = settings['mem_request']
          ENV['APP_INSTANCES'] = settings['instances'].to_s

          apply "kube/railsapp/rails_app_deploy.yml"
          apply "kube/railsapp/rails_app_service.yml"
        end
        if settings['worker_instances'] && settings['worker_instances'] > 0
          ENV['WORKER_MEM_LIMIT'] = settings['worker_mem_limit']
          ENV['WORKER_CPU_REQUEST'] = settings['worker_cpu_request'].to_s
          ENV['WORKER_CPU_LIMIT'] = settings['worker_cpu_limit'].to_s
          ENV['WORKER_MEM_REQUEST'] = settings['worker_mem_request']
          ENV['WORKER_INSTANCES'] = settings['worker_instances'].to_s
          ENV['WORKER_TIER'] = settings['worker_tier']
          ENV['WORKER_CMD'] = settings['worker_cmd']
          apply "kube/railsapp/worker_deploy.yaml"
        end

        #kubectl "rollout restart deployment #{app}"

        #only apply if domain exists
        if ENV['DNS_WEBSITE']
          # Install our Ingress that will link our load balancer to our service(s)
          apply "kube/railsapp/ingress.yml"

          # Add / modify DNS entry for DO loadbalancer (waits until service has public IP)
          register_domain("#{ENV['APP_NAME']}-ingress", ENV['DNS_WEBSITE'])

          # Add the certificate issuer (this must be done after first ingress and DNS is ready)
          apply "kube/dns_cert/cluster-issuer.yml"

          # Add our certificate
          apply "kube/dns_cert/certificate.yml"
        end

      end

      desc "Restart application"
      task :restart do
        kubectl "rollout restart deployment #{app.to_s}"
      end

      desc "Set the number of instances to run in the cluster"
      task :scale, [:count] => [:environment] do |t, args|
        kubectl "scale deployments/#{app.to_s}-deployment --replicas #{args[:count]}"
      end

      desc "Run database migrates the database"
      task :migrate do
        ENV['APP_NAME'] = app.to_s
        apply "kube/railsapp/job-migrate.yml"
      end

      desc "Tail the log files on production"
      task :logs do
        kubectl "logs -f -l app=#{app.to_s} --all-containers"
      end

      desc "Open a session to a pod on the cluster"
      task :shell do
        exec "kubectl exec -it #{find_first_pod_name(app.to_s)} -- sh"
      end

      desc "Runs a command in production"
      task :run, [:command] => [:environment] do |t, args|
        kubectl "exec -it #{find_first_pod_name(app.to_s)} echo $(#{args[:command]})"
      end

      desc "Run rails console in production"
      task :console do
        system "kubectl exec -it #{find_first_pod_name(app.to_s)} bundle exec rails console"
      end

      desc "Print the environment variables"
      task :config do
        ENV['APP_NAME'] = app.to_s
        system "kubectl exec -it #{find_first_pod_name(app.to_s)} printenv | sort"
      end

    end
  end

  desc 'Print useful information aout our Kubernete setup'
  task :list do
    kubectl 'get pods --all-namespaces'
    kubectl 'get services --all-namespaces'
    kubectl 'get ingresses --all-namespaces'
  end

  def apply(configuration)
    Dir.chdir(Rails.root)

    if !configuration.include?("http")
      puts %x{envsubst < #{configuration} | kubectl apply -f -}
    else
      kubectl "apply -f #{configuration}"
    end
  end

  def delete(configuration)
    Dir.chdir(Rails.root)

    if !configuration.include?("http")
      puts %x{envsubst < #{configuration} | kubectl delete -f -}
    else
      kubectl "delete -f #{configuration}"
    end
  end

  def kubectl_cmd(command)
    %x{ kubectl #{command} }
  end

  def kubectl(command)
    print %x{ kubectl #{command} }
  end

  def docker(command)
    puts "calling docker #{command}"
    print %x{ docker #{command} }
  end

  def doctl(command)
    print %x{ doctl #{command} }
  end

  def find_first_pod_name(appname)
    `kubectl get pods|grep #{appname}|awk '{print $1}'|head -n 1`.to_s.strip
  end

  def do_client
    return @client if @client
    require 'droplet_kit'
    token = ENV['DIGITAL_OCEAN_TOKEN']
    @client = DropletKit::Client.new(access_token: token)
  end

  def register_domain(ingress_name, full_domain)
    #wait that we have a public ip for ingress
    while true do
      kube_status = kubectl_cmd "get ingresses #{ingress_name}"
      ip_addr = kube_status[IP_ADDR_REGEX]
      break if ip_addr
      sleep 5
      puts "still waiting #{kube_status}"
    end

    puts "ip addr #{ip_addr} found, register domain #{full_domain}"

    domain = PublicSuffix.parse(full_domain)

    do_domain = do_client.domains.find(name: domain.domain)

    subdomain = domain.trd.blank? ? '@' : domain.trd

    puts "Domain not found in digital ocean" && return unless do_domain

    #get domain records
    records = do_client.domain_records.all(for_domain: domain.domain)
    existing_domain = records&.detect{|rec| rec['name']==subdomain && rec['type']=='A' }

    if existing_domain
      puts "Domain already registered"

      if existing_domain['data'] != ip_addr
        puts "Updating record #{existing_domain.inspect}}"
        existing_domain.data = ip_addr
        existing_domain.ttl = 60
        do_client.domain_records.update(existing_domain, for_domain: domain.domain, id: existing_domain.id)
      end
    else
      puts "Registering new subdomain"
      record = DropletKit::DomainRecord.new(
          type: 'A',
          name: subdomain,
          data: ip_addr,
          ttl: 60
      )
      do_client.domain_records.create(record, for_domain: domain.domain)
    end
  end

  def wait_loop(time_to_wait=2.minutes, message="Wait until process finishes")
    end_time = Time.now + time_to_wait
    puts message
    index = 1
    while Time.now < end_time
      sleep(1.seconds)
      printf("\r #{(end_time - Time.now).seconds.to_i}  ")
    end
  end
end