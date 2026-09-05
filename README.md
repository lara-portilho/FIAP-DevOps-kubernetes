# FIAP DevOps - Kubernetes (GitOps)

Repositorio de GitOps do Tech Challenge Fase 3 (Requisito 3: Entrega Continua & GitOps). Contem **apenas**
manifestos Kubernetes e Applications do ArgoCD para os 5 microsservicos do ToggleMaster — nenhuma
infraestrutura AWS e provisionada aqui (isso e o `FIAP-DevOps-terraform`).

## Como funciona

```
CI de cada servico (5 repos separados)
  -> build/test/lint/SAST/SCA
  -> docker build + trivy scan + push pra ECR (tag = commit hash)
  -> git clone/edit/push neste repo, atualizando manifests/<servico>/deployment.yaml
                                    |
                                    v
ArgoCD (instalado pelo FIAP-DevOps-terraform, helm_release.argocd)
  -> monitora este repo (6 Applications: 1 plataforma + 5 servicos)
  -> detecta a mudanca -> sincroniza automaticamente no cluster EKS
```

Nenhum pipeline de CI aplica nada direto no cluster — eles so escrevem no Git. Quem aplica no cluster e
sempre o ArgoCD.

## Estrutura

```
.
├── manifests/
│   ├── platform/              # Namespace, ConfigMap compartilhado, Ingress (5 rotas)
│   ├── auth-service/           # ConfigMap de migration, Deployment (com init container), Service
│   ├── flag-service/           # idem
│   ├── targeting-service/      # idem
│   ├── evaluation-service/      # Deployment (sem migration), Service, HPA (1-4, cpu 30%)
│   └── analytics-service/       # Deployment (sem migration), Service, HPA (1-3, cpu 70%)
├── argocd/                     # 6 Applications (uma por pasta de manifests/)
├── secrets/                    # gitignored -- Secrets com valores reais, NUNCA commitados
├── render-secrets.sh           # gera secrets/*.yaml com valores reais (RDS/Redis/SQS)
├── setup-service-key.sh        # gera a API key do evaluation-service chamando o auth-service
└── README.md
```

Cada Application do ArgoCD aponta pra uma pasta diferente de `manifests/`, entao cada microsservico e
gerenciado de forma independente (sync/rollback/historico separados na interface do ArgoCD). Os Secrets
ficam fora de `manifests/` de proposito — veja "Secrets neste repositorio" abaixo.

## Bootstrap (rodar uma vez, depois do `terraform apply` no repo de infra)

1. Configure o `kubectl` pro cluster (veja o README do `FIAP-DevOps-terraform`):

```bash
aws eks update-kubeconfig --region us-east-1 --name togglemaster-cluster
```

2. Gere os Secrets reais a partir dos outputs do Terraform (rode a partir da raiz deste repo, com
   `FIAP-DevOps-terraform` clonado ao lado):

```bash
export DB_PASSWORD='a mesma senha de db_password no terraform.tfvars'
./render-secrets.sh
```

Isso imprime a `MASTER_KEY` gerada — guarde, ela e usada no passo 5.

3. Aplique os Secrets direto no cluster (ficam em `secrets/`, que esta no `.gitignore` — nada disso
   passa pelo Git):

```bash
kubectl apply -f secrets/
```

4. Aplique as 6 Applications do ArgoCD (bootstrap manual, uma unica vez):

```bash
kubectl apply -f argocd/
```

Acompanhe a sincronizacao pela interface do ArgoCD (veja "Acessar a interface do ArgoCD" no README do
`FIAP-DevOps-terraform`) ou por `kubectl get pods -n togglemaster -w`.

5. Depois que os pods estiverem `Running`/`Ready`, gere a API key de servico:

```bash
export MASTER_KEY='a MASTER_KEY impressa no passo 2'
./setup-service-key.sh
```

6. Verifique:

```bash
kubectl get applications -n argocd
kubectl get pods -n togglemaster
kubectl get ingress -n togglemaster
```

## Atualizacao continua

A partir daqui, cada push na branch `main` de qualquer um dos 5 repos de servico
(`FIAP-DevOps-auth-service`, `flag-service`, `targeting-service`, `evaluation-service`,
`analytics-service`) builda, escaneia, publica a imagem no ECR e atualiza sozinho o
`manifests/<servico>/deployment.yaml` aqui — o ArgoCD pega a mudanca e sincroniza no cluster sem
nenhuma acao manual.

Para isso funcionar, cada um dos 5 repos de servico precisa ter um Secret `GITOPS_PAT`: um Personal
Access Token do GitHub (classic, escopo `repo`) usado pelo `git push` automatico no workflow de CI.

Nota: o ideal seria um fine-grained PAT restrito so a este repositorio, mas fine-grained PATs so deixam
selecionar repositorios pessoais que voce mesmo possui (ou de organizacoes) — nao aparece na lista um
repositorio pessoal de outra conta mesmo como collaborator. Por isso, quando o dono do token e apenas
collaborator (nao o dono da conta) neste repositorio, um PAT classic e o caminho que funciona; ele da
acesso a tudo que essa conta enxerga com o escopo `repo`, entao trate-o com o mesmo cuidado de uma senha.

## Secrets neste repositorio

Os Secrets (senha do RDS, chaves de servico) **nunca** passam pelo Git. `render-secrets.sh` gera os
arquivos em `secrets/`, que esta no `.gitignore` -- voce aplica com `kubectl apply -f secrets/`
diretamente no cluster.

Isso e intencional: nenhum dos 6 Applications do ArgoCD aponta pra `secrets/` (todos apontam pra
subpastas de `manifests/`), entao o ArgoCD nem sabe que esses Secrets existem -- não ha risco do
`selfHeal` reverter um `kubectl patch` (ex: o que o `setup-service-key.sh` faz), nem de credencial real
aparecer em commit, PR ou historico do repositorio. Os Deployments em `manifests/*/deployment.yaml`
referenciam esses Secrets por nome (`envFrom.secretRef`); o Kubernetes so exige que eles existam no
namespace quando o pod for de fato criado, entao a ordem entre aplicar `secrets/` e sincronizar o ArgoCD
nao e critica (mas o bootstrap abaixo aplica os Secrets primeiro, pra evitar erro transitorio de pod).

Isso e mais restrito do que o "Secret no Git" que a Fase 2 fazia (la a senha ficava no
`terraform.tfvars`/state do Terraform) -- aqui ela nao fica em lugar nenhum versionado, so no cluster.
Em um ambiente real de producao, o proximo passo seria um Secrets Manager de verdade (Sealed Secrets,
External Secrets Operator, AWS Secrets Manager) para nem depender de rodar um script manual.
