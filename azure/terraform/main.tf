terraform {
  required_providers {
    github = {
      source = "integrations/github"
      version = "4.9.4"  
    }
  }
}

# Configure the GitHub Provider
provider "github" {
  token = var.github_token
  owner = var.github_owner
}

resource "github_repository_file" "adpm" {
  repository          = "adc-performance-monitoring-scaling"
  branch              = "main"
  file                = "configs/consul_server.cfg"
  content             = format("http://%s:8500", azurerm_public_ip.consul_public_ip.ip_address)
  commit_message      = format("file contents update by application ID: %s", local.app_id)
  overwrite_on_create = true
}

provider azurerm {
    features {}
}

provider "consul" {
  address = "${azurerm_public_ip.consul_public_ip.ip_address}:8500"
}

#
# Create a random id
#
resource random_id id {
  byte_length = 2
}

locals {
  # Ids for multiple sets of EC2 instances, merged together
  hostname          = format("bigip.azure.%s.com", local.app_id)
  event_timestamp   = formatdate("YYYY-MM-DD hh:mm:ss",timestamp())
  app_id            = random_id.id.hex
}

#
# Create a resource group
#
resource azurerm_resource_group rg {
  name     = format("adpm-%s-rg", local.app_id)
  location = var.location
}

#
# Create a load balancer resources for bigip(s) via azurecli
#
resource "azurerm_public_ip" "nlb_public_ip" {
  name                = format("application-%s-nlb-pip", local.app_id)
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = [1]
}

data "template_file" "azure_cli_sh" {
  template = file("../configs/azure_lb.sh")
  depends_on = [azurerm_resource_group.rg, azurerm_public_ip.nlb_public_ip]
  vars = {
    rg_name         = azurerm_resource_group.rg.name
    public_ip       = azurerm_public_ip.nlb_public_ip.name
    lb_name         = format("application-%s-loadbalancer", local.app_id)         
  }
}

resource "null_resource" "azure-cli" {
  
  provisioner "local-exec" {
    # Call Azure CLI Script here
    command = data.template_file.azure_cli_sh.rendered
  }
}

#
#Create N-nic bigip
#
module bigip {
  count 		                 = var.bigip_count
  source                     = "../f5module/"
  prefix                     = format("application-%s-1nic", var.prefix)
  resource_group_name        = azurerm_resource_group.rg.name
  mgmt_subnet_ids            = [{ "subnet_id" = data.azurerm_subnet.mgmt.id, "public_ip" = true, "private_ip_primary" =  ""}]
  mgmt_securitygroup_ids     = [module.mgmt-network-security-group.network_security_group_id]
  availabilityZones          = var.availabilityZones
  app_name                   = var.app_name
  consul_ip                  = var.consul_ip
  app_id                     = local.app_id

  providers = {
    consul = consul
  }

  depends_on                 = [null_resource.azure-cli]
}

resource "null_resource" "clusterDO" {

  count = var.bigip_count

  provisioner "local-exec" {
    command = "cat > DO_1nic-instance${count.index}.json <<EOL\n ${module.bigip[count.index].onboard_do}\nEOL"
  }
  provisioner "local-exec" {
    when    = destroy
    command = "rm -rf DO_1nic-instance${count.index}.json"
  }
  depends_on = [ module.bigip.onboard_do]
}

#
# Create the Network Module to associate with BIGIP
#

module "network" {
  source              = "Azure/vnet/azurerm"
  vnet_name           = format("adpm-%s-vnet", local.app_id)
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = [var.cidr]
  subnet_prefixes     = [cidrsubnet(var.cidr, 8, 1)]
  subnet_names        = ["mgmt-subnet"]
  depends_on = [
    azurerm_resource_group.rg,
  ]

  tags = {
    environment = "dev"
    costcenter  = "it"
  }
}

data "azurerm_subnet" "mgmt" {
  name                 = "mgmt-subnet"
  virtual_network_name = module.network.vnet_name
  resource_group_name  = azurerm_resource_group.rg.name
  depends_on           = [module.network]
}

#
# Create the Network Security group Module to associate with BIGIP-Mgmt-Nic
#
module mgmt-network-security-group {
  source              = "Azure/network-security-group/azurerm"
  resource_group_name = azurerm_resource_group.rg.name
  security_group_name = format("application-%s-mgmt-nsg", local.app_id )
  
  depends_on = [
    azurerm_resource_group.rg,
  ]
  
  tags = {
    environment = "dev"
    costcenter  = "terraform"
  }
}

#
# Create the Network Security group Module to associate with BIGIP-Mgmt-Nic
#

resource "azurerm_network_security_rule" "mgmt_allow_https" {
  name                        = "Allow_Https"
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  destination_address_prefix  = "*"
  source_address_prefixes     = var.AllowedIPs
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = format("application-%s-mgmt-nsg", local.app_id)
  depends_on                  = [module.mgmt-network-security-group]
}
resource "azurerm_network_security_rule" "mgmt_allow_ssh" {
  name                        = "Allow_ssh"
  priority                    = 202
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  destination_address_prefix  = "*"
  source_address_prefixes     = var.AllowedIPs
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = format("application-%s-mgmt-nsg", local.app_id)
  depends_on                  = [module.mgmt-network-security-group]
}
resource "azurerm_network_security_rule" "mgmt_allow_https2" {
  name                        = "Allow_Https_8443"
  priority                    = 201
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "8443"
  destination_address_prefix  = "*"
  source_address_prefixes     = var.AllowedIPs
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = format("application-%s-mgmt-nsg", local.app_id)
  depends_on                  = [module.mgmt-network-security-group]
}

resource "azurerm_network_security_rule" "mgmt_allow_alertforwarder" {
  name                        = "Allow_8000"
  priority                    = 204
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "8000"
  destination_address_prefix  = "*"
  source_address_prefixes     = var.AllowedIPs
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = format("application-%s-mgmt-nsg", local.app_id)
  depends_on                  = [module.mgmt-network-security-group]
}

#
# Create backend application workloads
#
resource "azurerm_network_interface" "appnic" {
 count               = var.workload_count
 name                = "app_nic_${count.index}"
 location            = azurerm_resource_group.rg.location
 resource_group_name = azurerm_resource_group.rg.name

 ip_configuration {
   name                          = "testConfiguration"
   subnet_id                     = data.azurerm_subnet.mgmt.id
   private_ip_address_allocation = "dynamic"
 }
}

resource "azurerm_managed_disk" "appdisk" {
 count                = var.workload_count
 name                 = "datadisk_existing_${count.index}"
 location             = azurerm_resource_group.rg.location
 resource_group_name  = azurerm_resource_group.rg.name
 storage_account_type = "Standard_LRS"
 create_option        = "Empty"
 disk_size_gb         = "1023"
}

resource "azurerm_availability_set" "avset" {
 name                         = "avset"
 location                     = azurerm_resource_group.rg.location
 resource_group_name          = azurerm_resource_group.rg.name
 platform_fault_domain_count  = 2
 platform_update_domain_count = 2
 managed                      = true
}

data "template_file" "backendapp" {
  template          = file("backendapp.tpl")
  vars = {
    app_id              = local.app_id
    consul_ip           = var.consul_ip
  }
}

resource "azurerm_virtual_machine" "app" {
 count                 = var.workload_count
 name                  = "app_vm_${count.index}"
 location              = azurerm_resource_group.rg.location
 availability_set_id   = azurerm_availability_set.avset.id
 resource_group_name   = azurerm_resource_group.rg.name
 network_interface_ids = [element(azurerm_network_interface.appnic.*.id, count.index)]
 vm_size               = "Standard_DS1_v2"


 # Uncomment this line to delete the OS disk automatically when deleting the VM
 delete_os_disk_on_termination = true

 # Uncomment this line to delete the data disks automatically when deleting the VM
 delete_data_disks_on_termination = true

 storage_image_reference {
   publisher = "Canonical"
   offer     = "UbuntuServer"
   sku       = "18.04-LTS"
   version   = "latest"
 }

 storage_os_disk {
   name              = "myosdisk${count.index}"
   caching           = "ReadWrite"
   create_option     = "FromImage"
   managed_disk_type = "Standard_LRS"
 }

 # Optional data disks
 storage_data_disk {
   name              = "datadisk_new_${count.index}"
   managed_disk_type = "Standard_LRS"
   create_option     = "Empty"
   lun               = 0
   disk_size_gb      = "1023"
 }

 storage_data_disk {
   name            = element(azurerm_managed_disk.appdisk.*.name, count.index)
   managed_disk_id = element(azurerm_managed_disk.appdisk.*.id, count.index)
   create_option   = "Attach"
   lun             = 1
   disk_size_gb    = element(azurerm_managed_disk.appdisk.*.disk_size_gb, count.index)
 }

 os_profile {
   computer_name  = format("workload-%s", count.index)
   admin_username = "appuser"
   admin_password = var.upassword
   custom_data    = data.template_file.backendapp.rendered
 }

 os_profile_linux_config {
   disable_password_authentication = false
 }

  tags = {
    Name                = "${var.environment}-backendapp_${count.index}"
    environment         = var.environment
    owner               = var.owner
    group               = var.group
    costcenter          = var.costcenter
    application         = var.application
    tag_name            = "Env"
    value               = "consul"
    propagate_at_launch = true
    key                 = "Env"
    value               = "consul"
  }
}

#
# Create consul server
#
 resource "azurerm_public_ip" "consul_public_ip" {
  name                = "pip-mgmt-consul"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"   # Static is required due to the use of the Standard sku
  tags = {
    Name   = "pip-mgmt-consul"
    source = "terraform"
  }
}

resource "azurerm_network_interface" "consulvm-ext-nic" {
  name               = "${local.app_id}-consulvm-ext-nic"
  location           = var.location
  resource_group_name = azurerm_resource_group.rg.name
  ip_configuration {
    name                          = "primary"
    subnet_id                     =  data.azurerm_subnet.mgmt.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.2.1.100"
    primary                       = true
    public_ip_address_id          = azurerm_public_ip.consul_public_ip.id
  }

  tags = {
    Name        = "${local.app_id}-consulvm-ext-int"
    application = "consulserver"
    tag_name    = "Env"
    value       = "consul"
  }
}

resource "azurerm_virtual_machine" "consulvm" {
  name                  = "consulvm"
  location              = var.location
  resource_group_name   = azurerm_resource_group.rg.name
  network_interface_ids = [azurerm_network_interface.consulvm-ext-nic.id]
  vm_size               = "Standard_DS1_v2"
  
  # Uncomment this line to delete the OS disk automatically when deleting the VM
  delete_os_disk_on_termination = true

  # Uncomment this line to delete the data disks automatically when deleting the VM
  delete_data_disks_on_termination = true
  
  storage_os_disk {
    name              = "consulvmOsDisk"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Premium_LRS"
  }

  storage_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }

  os_profile {
    computer_name  = "consulvm"
    admin_username = "consuluser"
    admin_password = var.upassword
    custom_data    = file("../configs/consul.sh")

  }

  os_profile_linux_config {
    disable_password_authentication = false
  }

  tags = {
    Name                = "${local.app_id}-consulvm"
    tag_name            = "Env"
    application         = "consulserver"
    value               = "consul"
    propagate_at_launch = true
  }
}

data "azurerm_public_ip" "consul_public_ip" {
  name                = "pip-mgmt-consul"
  resource_group_name = azurerm_resource_group.rg.name
  depends_on = [
    azurerm_virtual_machine.consulvm
  ]
}

#
#  Create ELK stack
#

resource "azurerm_public_ip" "elk_public_ip" {
  name                = "pip-mgmt-elk"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"   # Static is required due to the use of the Standard sku
  tags = {
    Name   = "pip-mgmt-elk"
    source = "terraform"
  }
}

data  "azurerm_public_ip" "elk_public_ip" {
  name                = azurerm_public_ip.elk_public_ip.name
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_network_interface" "elkvm-ext-nic" {
  name               = "${local.app_id}-elkvm-ext-nic"
  location           = var.location
  resource_group_name = azurerm_resource_group.rg.name
  ip_configuration {
    name                          = "primary"
    subnet_id                     =  data.azurerm_subnet.mgmt.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.2.1.125"
    primary                       = true
    public_ip_address_id          = azurerm_public_ip.elk_public_ip.id
  }

  tags = {
    Name        = "${local.app_id}-elkvm-ext-int"
    application = "elkserver"
    tag_name    = "Env"
    value       = "elk"
  }
}

resource "azurerm_virtual_machine" "elkvm" {
  name                  = "elkvm"
  location              = var.location
  resource_group_name   = azurerm_resource_group.rg.name
  network_interface_ids = [azurerm_network_interface.elkvm-ext-nic.id]
  vm_size               = "Standard_DS3_v2"

  # Uncomment this line to delete the OS disk automatically when deleting the VM
  delete_os_disk_on_termination = true

  # Uncomment this line to delete the data disks automatically when deleting the VM
  delete_data_disks_on_termination = true
  
  storage_os_disk {
    name              = "elkvmOsDisk"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Premium_LRS"
  }
  
  storage_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "16.04.0-LTS"
    version   = "latest"
  }

  os_profile {
    computer_name  = "elkvm"
    admin_username = "elkuser"
    admin_password = var.upassword
    custom_data    = file("elk.sh")

  }

  os_profile_linux_config {
    disable_password_authentication = false
  }

  tags = {
    Name                = "${local.app_id}-elkvm"
    tag_name            = "Env"
    value               = "elk"
    propagate_at_launch = true
  }

  connection {
      type     = "ssh"
      user     = "elkuser"
      password = var.upassword
      host     = data.azurerm_public_ip.elk_public_ip.ip_address
  }
  
  provisioner "file" {
    source      = "elkupdate.sh"
    destination = "/home/elkuser/elkupdate.sh"
  }
}

#
# Update central consul server
#
resource "consul_keys" "app" {
  datacenter = "dc1"
  # Set the CNAME of our load balancer as a key
  key {
    path  = format("adpm/common/scaling/bigip/min")
    value = var.bigip_min
  }
  key {
    path  = format("adpm/common/scaling/bigip/max")
    value = var.bigip_max
  }
  key {
    path  = format("adpm/common/scaling/workload/min")
    value = var.workload_min
  }
  key {
    path  = format("adpm/common/scaling/workload/max")
    value = var.workload_max
  }
  key {
    path  = format("adpm/common/scaling/min_scaling_interval_seconds")
    value = var.scale_interval
  }
  key {
    path  = format("adpm/applications/%s/scaling/bigip/current_count", local.app_id)
    value = var.bigip_count
  }
  key {
    path  = format("adpm/applications/%s/scaling/workload/current_count", local.app_id)
    value = var.workload_count
  }
  key {
    path  = format("adpm/applications/%s/create_timestamp", local.app_id)
    value = local.event_timestamp
  }
  key {
    path  = format("adpm/applications/%s/scaling/bigip/last_modified_timestamp", local.app_id)
    value = local.event_timestamp
  }
  key {
    path  = format("adpm/applications/%s/scaling/workload/last_modified_timestamp", local.app_id)
    value = local.event_timestamp
  }
  key {
    path  = format("adpm/applications/%s/scaling/is_running", local.app_id)
    value = "false"
  } 
  key {
    path  = format("adpm/applications/%s/terraform/outputs/bigip_mgmt", local.app_id)
    value = "https://${module.bigip.0.mgmtPublicIP}:8443"
  }
  key {
    path  = format("adpm/applications/%s/terraform/outputs/application_address", local.app_id )
    value = "https://${azurerm_public_ip.nlb_public_ip.ip_address}"
  }
}

data "template_file" "tfstate" {
  template          = file("tfstate.tpl")
  vars = {
    app_id              = local.app_id
    consul_ip           = azurerm_public_ip.consul_public_ip.ip_address
  }
}

resource "local_file" "tfstate" {
  content  = data.template_file.tfstate.rendered
  filename = "tfstate.tf"
}

#
#  Create Alert Forwarder
#

data "template_file" "alertfwd" {
  template          = file("alertfwd.tpl")
  vars = {
    github_token    = var.github_token
  }
}

resource "azurerm_public_ip" "af_public_ip" {
  name                = "pip-mgmt-af"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"   # Static is required due to the use of the Standard sku
  tags = {
    Name   = "pip-mgmt-af"
    source = "terraform"
  }
}

data  "azurerm_public_ip" "af_public_ip" {
  name                = azurerm_public_ip.af_public_ip.name
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_network_interface" "afvm-ext-nic" {
  name               = "${local.app_id}-afvm-ext-nic"
  location           = var.location
  resource_group_name = azurerm_resource_group.rg.name
  ip_configuration {
    name                          = "primary"
    subnet_id                     =  data.azurerm_subnet.mgmt.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.2.1.150"
    primary                       = true
    public_ip_address_id          = azurerm_public_ip.af_public_ip.id
  }

  tags = {
    Name        = "${local.app_id}-afvm-ext-int"
    application = "afserver"
    tag_name    = "Env"
    value       = "af"
  }
}

resource "azurerm_virtual_machine" "afvm" {
  name                  = "afvm"
  location              = var.location
  resource_group_name   = azurerm_resource_group.rg.name
  network_interface_ids = [azurerm_network_interface.afvm-ext-nic.id]
  vm_size               = "Standard_DS3_v2"

  # Uncomment this line to delete the OS disk automatically when deleting the VM
  delete_os_disk_on_termination = true

  # Uncomment this line to delete the data disks automatically when deleting the VM
  delete_data_disks_on_termination = true
  
  storage_os_disk {
    name              = "afvmOsDisk"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Premium_LRS"
  }
  
  storage_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "16.04.0-LTS"
    version   = "latest"
  }

  os_profile {
    computer_name  = "afvm"
    admin_username = "afuser"
    admin_password = var.upassword
    custom_data    = data.template_file.alertfwd.rendered
  }

  os_profile_linux_config {
    disable_password_authentication = false
  }

  tags = {
    Name                = "${local.app_id}-afvm"
    tag_name            = "Env"
    value               = "af"
    propagate_at_launch = true
  }

  connection {
      type     = "ssh"
      user     = "afuser"
      password = var.upassword
      host     = data.azurerm_public_ip.af_public_ip.ip_address
  }
}