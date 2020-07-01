#initialize elastic instance with copied settings
options = Rails.application.config_for(:elasticsearch)
$kube_es_client = Elasticsearch::Client.new(options) if defined?(Elasticsearch::Client)
Elasticsearch::Model.client = $kube_es_client if defined?(Elasticsearch::Model)
