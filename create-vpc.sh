#!/bin/bash

# Definindo o arquivo onde as últimas entradas serão armazenadas, agora em /tmp
config_file="/tmp/.last_aws_config"

# Verificar se o arquivo de configuração existe e ler os valores
if [ -f "$config_file" ]; then
  source "$config_file"
else
  LAST_AWS_PROFILE=""
  LAST_AWS_REGION=""
  LAST_VPC_NAME=""
fi

# Solicitar ao usuário que especifique o profile da AWS CLI, a região e o nome da VPC com valores padrão
read -p "Enter your AWS CLI profile name [$LAST_AWS_PROFILE]: " AWS_PROFILE
AWS_PROFILE=${AWS_PROFILE:-$LAST_AWS_PROFILE}

read -p "Enter your AWS region [$LAST_AWS_REGION]: " AWS_REGION
AWS_REGION=${AWS_REGION:-$LAST_AWS_REGION}

read -p "Enter a name for your VPC [$LAST_VPC_NAME]: " VPC_NAME
VPC_NAME=${VPC_NAME:-$LAST_VPC_NAME}

# Salvar as últimas entradas no arquivo de configuração para uso futuro
echo "LAST_AWS_PROFILE=$AWS_PROFILE" > "$config_file"
echo "LAST_AWS_REGION=$AWS_REGION" >> "$config_file"
echo "LAST_VPC_NAME=$VPC_NAME" >> "$config_file"

# Definir a região para as operações da AWS CLI
export AWS_DEFAULT_REGION=$AWS_REGION

echo "Starting VPC setup..."

# 1. Criar a VPC
vpc_id=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query 'Vpc.VpcId' --output text --profile $AWS_PROFILE)
echo "VPC Created with ID: $vpc_id"

# Tagging the VPC with the provided name
aws ec2 create-tags --resources $vpc_id --tags Key=Name,Value="$VPC_NAME" --profile $AWS_PROFILE
echo "VPC named '$VPC_NAME'"

# Ativar o DNS hostname para a VPC
aws ec2 modify-vpc-attribute --vpc-id $vpc_id --enable-dns-hostnames --profile $AWS_PROFILE

# Arrays para armazenar IDs das subnets
public_subnet_ids=()
private_subnet_ids=()

# 2. Criar subnets públicas e privadas em 3 AZs
for i in {0..2}; do
  az=$(aws ec2 describe-availability-zones --query "AvailabilityZones[$i].ZoneName" --output text --profile $AWS_PROFILE --region $AWS_REGION)

  # Criar subnet pública
  public_subnet_id=$(aws ec2 create-subnet --vpc-id $vpc_id --cidr-block "10.0.$((1 + i * 2)).0/24" --availability-zone $az --query 'Subnet.SubnetId' --output text --profile $AWS_PROFILE)
  echo "Public Subnet Created with ID: $public_subnet_id in $az"
  public_subnet_ids+=($public_subnet_id)
  
  # Criar subnet privada
  private_subnet_id=$(aws ec2 create-subnet --vpc-id $vpc_id --cidr-block "10.0.$((2 + i * 2)).0/24" --availability-zone $az --query 'Subnet.SubnetId' --output text --profile $AWS_PROFILE)
  echo "Private Subnet Created with ID: $private_subnet_id in $az"
  private_subnet_ids+=($private_subnet_id)
done

# 3. Criar e anexar Internet Gateway à VPC
igw_id=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text --profile $AWS_PROFILE)
aws ec2 attach-internet-gateway --internet-gateway-id $igw_id --vpc-id $vpc_id --profile $AWS_PROFILE
echo "Internet Gateway Created and Attached with ID: $igw_id"

# 4. Criar NAT Gateway na primeira subnet pública criada
eip_allocation_id=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text --profile $AWS_PROFILE)
nat_gateway_id=$(aws ec2 create-nat-gateway --subnet-id ${public_subnet_ids[0]} --allocation-id $eip_allocation_id --query 'NatGateway.NatGatewayId' --output text --profile $AWS_PROFILE)
echo "NAT Gateway Created with ID: $nat_gateway_id"
aws ec2 wait nat-gateway-available --nat-gateway-ids $nat_gateway_id --profile $AWS_PROFILE
echo "NAT Gateway is now available."

# 5. Configurar tabelas de rotas
public_route_table_id=$(aws ec2 create-route-table --vpc-id $vpc_id --query 'RouteTable.RouteTableId' --output text --profile $AWS_PROFILE)
aws ec2 create-route --route-table-id $public_route_table_id --destination-cidr-block 0.0.0.0/0 --gateway-id $igw_id --profile $AWS_PROFILE
for subnet_id in "${public_subnet_ids[@]}"; do
  aws ec2 associate-route-table --subnet-id $subnet_id --route-table-id $public_route_table_id --profile $AWS_PROFILE
done

private_route_table_id=$(aws ec2 create-route-table --vpc-id $vpc_id --query 'RouteTable.RouteTableId' --output text --profile $AWS_PROFILE)
aws ec2 create-route --route-table-id $private_route_table_id --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $nat_gateway_id --profile $AWS_PROFILE
for subnet_id in "${private_subnet_ids[@]}"; do
  aws ec2 associate-route-table --subnet-id $subnet_id --route-table-id $private_route_table_id --profile $AWS_PROFILE
done

echo "VPC setup complete. Public and private subnets are configured with internet access."
