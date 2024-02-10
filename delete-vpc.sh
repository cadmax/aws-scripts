#!/bin/bash

# Definindo o arquivo onde as últimas entradas serão armazenadas, agora em /tmp
config_file="/tmp/.last_aws_config"

# Verificar se o arquivo de configuração existe e ler os valores
if [ -f "$config_file" ]; then
  source "$config_file"
else
  LAST_AWS_PROFILE=""
  LAST_AWS_REGION=""
  LAST_VPC_ID=""
fi

# Solicitar ao usuário que especifique o profile da AWS CLI, a região e o nome da VPC com valores padrão
read -p "Enter your AWS CLI profile name [$LAST_AWS_PROFILE]: " AWS_PROFILE
AWS_PROFILE=${AWS_PROFILE:-$LAST_AWS_PROFILE}

read -p "Enter your AWS region [$LAST_AWS_REGION]: " AWS_REGION
AWS_REGION=${AWS_REGION:-$LAST_AWS_REGION}

read -p "Enter the id for your VPC [$LAST_VPC_ID]: " VPC_ID
VPC_ID=${VPC_ID:-$LAST_VPC_ID}

# Salvar as últimas entradas no arquivo de configuração para uso futuro
echo "LAST_AWS_PROFILE=$AWS_PROFILE" > "$config_file"
echo "LAST_AWS_REGION=$AWS_REGION" >> "$config_file"
echo "LAST_VPC_ID=$VPC_ID" >> "$config_file"

# Definir a região para as operações da AWS CLI
export AWS_DEFAULT_REGION=$AWS_REGION

echo "Starting deletion process for VPC $VPC_ID..."

# Deletar NAT Gateways
echo "Deleting NAT Gateways..."
nat_gateways=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" --query 'NatGateways[*].NatGatewayId' --output text --profile $AWS_PROFILE)
for nat_id in $nat_gateways; do
  echo "Deleting NAT Gateway: $nat_id"
  aws ec2 delete-nat-gateway --nat-gateway-id $nat_id --profile $AWS_PROFILE
  echo "Waiting for NAT Gateway $nat_id to be deleted..."
  aws ec2 wait nat-gateway-deleted --nat-gateway-ids $nat_id --profile $AWS_PROFILE
done

# Deletar subnets
echo "Deleting subnets..."
subnets=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[*].SubnetId' --output text --profile $AWS_PROFILE)
for subnet_id in $subnets; do
  # Deletar ENIs associadas à subnet
  enis=$(aws ec2 describe-network-interfaces --filters "Name=subnet-id,Values=$subnet_id" --query 'NetworkInterfaces[*].NetworkInterfaceId' --output text --profile $AWS_PROFILE)
  for eni_id in $enis; do
    echo "Deleting network interface: $eni_id"
    aws ec2 delete-network-interface --network-interface-id $eni_id --profile $AWS_PROFILE
  done
  
  echo "Deleting subnet: $subnet_id"
  aws ec2 delete-subnet --subnet-id $subnet_id --profile $AWS_PROFILE
done

# Deletar Internet Gateway
echo "Deleting Internet Gateways..."
igws=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query 'InternetGateways[*].InternetGatewayId' --output text --profile $AWS_PROFILE)
for igw_id in $igws; do
  echo "Detaching and Deleting Internet Gateway: $igw_id"
  aws ec2 detach-internet-gateway --internet-gateway-id $igw_id --vpc-id $VPC_ID --profile $AWS_PROFILE
  aws ec2 delete-internet-gateway --internet-gateway-id $igw_id --profile $AWS_PROFILE
done

# Deletar Route Tables
echo "Deleting Route Tables..."
route_tables=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --query 'RouteTables[*].RouteTableId' --output text --profile $AWS_PROFILE)
for rt_id in $route_tables; do
  echo "Deleting Route Table: $rt_id"
  aws ec2 delete-route-table --route-table-id $rt_id --profile $AWS_PROFILE 2>/dev/null || echo "Skipping main route table: $rt_id"
done

# Deletar Security Groups
echo "Deleting Security Groups..."
security_groups=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[*].GroupId' --output text --profile $AWS_PROFILE)
for sg_id in $security_groups; do
  echo "Deleting Security Group: $sg_id"
  aws ec2 delete-security-group --group-id $sg_id --profile $AWS_PROFILE 2>/dev/null || echo "Skipping default security group: $sg_id"
done

# Finalmente, deletar a VPC
echo "Deleting VPC: $VPC_ID"
aws ec2 delete-vpc --vpc-id $VPC_ID --profile $AWS_PROFILE

echo "VPC $VPC_ID and all its resources have been deleted."
