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
├── secrets/                    # gitignored -- Secrets/ConfigMap com valores reais, NUNCA commitados
├── bootstrap.sh                # roda o bootstrap inteiro de uma vez (chama render-secrets.sh)
├── render-secrets.sh           # gera secrets/*.yaml com valores reais (RDS/Redis/SQS + API key semeada)
└── README.md
```

Cada Application do ArgoCD aponta pra uma pasta diferente de `manifests/`, entao cada microsservico e
gerenciado de forma independente (sync/rollback/historico separados na interface do ArgoCD). Os Secrets
ficam fora de `manifests/` de proposito — veja "Secrets neste repositorio" abaixo.

## Bootstrap (rodar depois de todo `terraform apply` no repo de infra -- inclusive apos um teardown/recriacao)

### Caminho rapido

```bash
export DB_PASSWORD='a mesma senha de db_password no terraform.tfvars'
./bootstrap.sh
```

Isso roda a sequencia inteira (kubeconfig → namespace → secrets → Applications do ArgoCD) e termina
acompanhando o status dos pods (`kubectl get pods -w`, Ctrl+C pra sair quando tudo estiver `Running`).

**Importante se a infra acabou de ser recriada do zero:** os Deployments comecam apontando pra uma
imagem placeholder ate que os 5 CIs de servico rodem pelo menos uma vez (build → scan → push no ECR →
commit da tag aqui). Se for a primeira subida depois de um `terraform destroy` + `apply`, dispare um
push (ou "Re-run all jobs") em cada um dos 5 repositorios de servico antes ou depois de rodar o
`bootstrap.sh` — os pods ficam em `ImagePullBackOff` ate isso acontecer, e o ArgoCD atualiza sozinho
assim que a imagem real existir.

Se algo falhar no meio do script, ele para nesse ponto — rode os passos manuais abaixo a partir de onde
parou pra debugar.

### Passo a passo manual (o que o bootstrap.sh faz por baixo dos panos)

1. Configure o `kubectl` pro cluster (veja o README do `FIAP-DevOps-terraform`):

```bash
aws eks update-kubeconfig --region us-east-1 --name togglemaster-cluster
```

2. Crie o namespace (ele so seria criado pelo ArgoCD ao sincronizar o Application da plataforma, mas
   os Secrets do passo seguinte precisam dele antes disso):

```bash
kubectl create namespace togglemaster
```

3. Gere os Secrets reais a partir dos outputs do Terraform (rode a partir da raiz deste repo, com
   `FIAP-DevOps-terraform` clonado ao lado) e aplique no cluster:

```bash
export DB_PASSWORD='a mesma senha de db_password no terraform.tfvars'
./render-secrets.sh
kubectl apply -f secrets/
```

4. Aplique as 6 Applications do ArgoCD (bootstrap manual, uma unica vez):

```bash
kubectl apply -f argocd/
```

Acompanhe a sincronizacao pela interface do ArgoCD (veja "Acessar a interface do ArgoCD" no README do
`FIAP-DevOps-terraform`) ou por `kubectl get pods -n togglemaster -w`.

5. Verifique:

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
`selfHeal` reverter uma mudanca feita fora do Git, nem de credencial real aparecer em commit, PR ou
historico do repositorio. Os Deployments em `manifests/*/deployment.yaml` referenciam esses Secrets por
nome (`envFrom.secretRef`); o Kubernetes so exige que eles existam no namespace quando o pod for de fato
criado, entao a ordem entre aplicar `secrets/` e sincronizar o ArgoCD nao e critica (mas o bootstrap
aplica os Secrets primeiro, pra evitar erro transitorio de pod).

### SERVICE_API_KEY do evaluation-service

O `auth-service` guarda so o hash SHA-256 de cada API key (nunca o valor em texto puro, veja
`FIAP-DevOps-auth-service/key.go`). Por isso, `render-secrets.sh` gera a key, calcula o hash, e escreve
ambos:
- o valor em texto puro em `secrets/evaluation-service-secret.yaml` (`SERVICE_API_KEY`);
- o hash em `secrets/auth-db-seed-configmap.yaml` (ConfigMap `auth-db-seed`, montado pelo init container
  do `auth-service` e inserido na tabela `api_keys` junto com a migration do schema).

Isso elimina a necessidade de esperar o `auth-service` subir pra chamar a API `/admin/keys` depois —
a key ja existe no banco desde o primeiro boot do pod. Se voce rodar `render-secrets.sh` de novo com uma
key nova em um cluster que ja esta de pe, o pod do `auth-service` precisa ser recriado pra rodar o
`seed.sql` de novo:

```bash
kubectl rollout restart deployment/auth-service -n togglemaster
```

Isso e mais restrito do que o "Secret no Git" que a Fase 2 fazia (la a senha ficava no
`terraform.tfvars`/state do Terraform) -- aqui ela nao fica em lugar nenhum versionado, so no cluster.
Em um ambiente real de producao, o proximo passo seria um Secrets Manager de verdade (Sealed Secrets,
External Secrets Operator, AWS Secrets Manager) para nem depender de rodar um script manual.
