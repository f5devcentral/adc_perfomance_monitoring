# Setup Onboarding scripts
data "template_file" "init_file" {
  template = file("${path.module}/onboard.tpl")

  vars = {
    admin_username = var.f5_username
    admin_password = local.upass
    DO_URL         = var.doPackageUrl
    AS3_URL        = var.as3PackageUrl
    TS_URL         = var.tsPackageUrl
    libs_dir       = var.libs_dir
    onboard_log    = var.onboard_log
    DO_Document    = data.template_file.vm01_do_json.rendered
    AS3_Document   = data.template_file.as3_json.rendered
    TS_Document    = data.template_file.ts_json.rendered
    app_name        = var.app_name
  }
}

data "template_file" "vm01_do_json" {
  template = file("../configs/do.json")

  vars = {
    hostname        = local.hostname
    local_selfip       = "-external-self-address-"
    gateway            = var.ext_gw
    dns_server         = var.dns_server
    ntp_server         = var.ntp_server
    timezone           = var.timezone
  }
}

data "template_file" "as3_json" {
  depends_on = [null_resource.azure_cli_add]
  template = file("../configs/as3.json")
  vars = {
    web_pool        = "myapp-${var.app}"
    app_name        = var.app_name
    consul_ip       = var.consul_ip
  }
}

data "template_file" "ts_json" {
  template   = file("${../configs/ts.json")
  vars = {
    region          = data.azurerm_resource_group.bigiprg.location
    splunkIP        = "206.124.129.187"
    splunkHEC       = "f02428fa-bc2e-42de-8368-ee25fe35ef5d"
//    logStashIP         = "10.2.1.125"
//    law_id             = azurerm_log_analytics_workspace.law.workspace_id
//    law_primarykey     = azurerm_log_analytics_workspace.law.primary_shared_key

  }
}