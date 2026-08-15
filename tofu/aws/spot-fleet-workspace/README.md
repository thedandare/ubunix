# Spot Fleet Workspace

Este workspace usa AWS EC2 Spot Fleet para criar instâncias NixOS com custo reduzido.

## Configuração

1. Copie `terraform.tfvars.example` para `terraform.tfvars`:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

2. Ajuste os valores conforme necessário. O `subnet_ids` já está configurado com o subnet existente da sua infraestrutura.

## Diferenças do workspace principal

- Usa `aws_ec2_spot_fleet_request` em vez de `aws_instance`
- Usa `aws_launch_template` para definir a configuração das instâncias
- Inclui IAM role específico para spot fleet (`aws-ec2-spot-fleet-tagging-role`)
- Estratégia de alocação: `priceCapacityOptimized`
- Tipo de request: `maintain` (mantém a capacidade automaticamente)

## Variáveis importantes

- `node_count`: Número de instâncias desejadas no spot fleet
- `subnet_ids`: Lista de subnet IDs onde as instâncias serão criadas
- `instance_type`: Tipo de instância (padrão: t3.small)
- `enable_spot_instances`: Habilita instâncias spot (padrão: true)

## Uso

```bash
# Inicializar o workspace
tofu init

# Planejar as mudanças
tofu plan

# Aplicar as mudanças
tofu apply

# Destruir recursos
tofu destroy
```

## Notas

- As instâncias spot podem ser interrompidas pela AWS a qualquer momento
- O spot fleet tentará manter a capacidade configurada automaticamente
- Configure `spot_max_price` se quiser limitar o preço máximo
- O comportamento padrão em interrupção é `terminate`
