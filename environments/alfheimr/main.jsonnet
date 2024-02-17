local application = import 'application.libsonnet';
local externalDns = import 'external-dns.libsonnet';
local gotify = import 'gotify.libsonnet';
local wikijs = import 'wikijs.libsonnet';
local blocky = import 'blocky.libsonnet';

local defaults = {
  cluster: 'alfheimr',
  domain: 'alfheimr.arleskog.se',
  repoURL: 'https://github.com/albertarleskog/clusters.git',
  path: 'environments/%s' % self.cluster,
};

local createApplication(config) =
  application.new(config.name)
  + application.spec.withSource({ path: '%s/%s' % [defaults.path, config.name], repoURL: defaults.repoURL })
  + application.spec.withDestination({ namespace: config.namespace });

local root = {
  'cert-manager': {}
                  + {
                    [endpoint.key]: {
                      apiVersion: 'cert-manager.io/v1',
                      kind: 'ClusterIssuer',
                      metadata: {
                        name: endpoint.key,
                      },
                      spec: {
                        acme: {
                          server: endpoint.value,
                          email: 'albert@arleskog.se',
                          privateKeySecretRef: {
                            name: endpoint.key,
                          },
                          solvers: [
                            { http01: { ingress: { ingressClassName: 'nginx' } } },
                          ],
                        },
                      },
                    }
                    for endpoint in std.objectKeysValues({
                      'letsencrypt-prod': 'https://acme-v02.api.letsencrypt.org/directory',
                      'letsencrypt-stag': 'https://acme-staging-v02.api.letsencrypt.org/directory',
                    })
                  },
  'external-dns': externalDns(
    {
      image: 'docker.io/bitnami/external-dns:0.14.0',
      namespace: 'external-dns',
      name: 'external-dns',
    }
  ),
  metallb: {
    pools: {
      apiVersion: 'metallb.io/v1beta1',
      kind: 'IPAddressPool',
      metadata: {
        name: 'hetzner-public',
        namespace: 'metallb-system',
      },
      spec: {
        addresses: [
          '37.27.42.70/32',
          '2a01:4f9:c012:c1bd:20::1/96',
        ],
      },
    },
  },
  gotify: gotify({
    name: "gotify",
    namespace: "gotify",
    image: "ghcr.io/gotify/server-arm64:2.4",
    subdomain: "notify",
    domain: defaults.domain
  }),
  wikijs: wikijs({
    clusterIssuer: "letsencrypt-prod",
    version: "2",
    domain: defaults.domain,
  }),
  blocky: blocky({
    name: "blocky",
    image: "spx01/blocky:v0.23",
    namespace: "blocky",
    subdomain: "dns",
    domain: defaults.domain,
    replicas: 3
  })
};

local applications = {
  root: createApplication({ name: 'root', namespace: 'argocd' })
        + application.spec.withSource({ path: 'environments/%s' % defaults.cluster, repoURL: defaults.repoURL }),
  argocd: createApplication({ name: 'argocd', namespace: 'argocd' })
          + application.spec.withSource({
            repoURL: 'https://argoproj.github.io/argo-helm',
            targetRevision: '5.51.2',
            chart: 'argo-cd',
            helm: {
              values: |||
                configs:
                  cm:
                    url: https://argocd.{{ .Values.global.domain_name }}
                    oidc.config: |
                      name: Keycloak
                      issuer: {{ .Values.global.oidc_url }}/realms/default
                      clientID: argocd_alfheimr
                      clientSecret: $oidc.keycloak.clientSecret
                      requestedScopes: [openid, profile, email, roles]
                  rbac:
                    policy.csv: |
                      g, admin, role:admin
                    scopes: "[roles]"
                dex:
                  enabled: false
                server:
                  ingress:
                    enabled: true
                    ingressClassName: nginx
                    annotations:
                      nginx.ingress.kubernetes.io/backend-protocol: https
                      cert-manager.io/cluster-issuer: letsencrypt-prod
                      external-dns.alpha.kubernetes.io/hostname: argocd.{{ .Values.global.domain_name }}
                    hosts:
                      - argocd.{{ .Values.global.domain_name }}
                    tls:
                      - secretName: argocd-{{ .Values.global.domain_name }}-cert
                        hosts:
                          - argocd.{{ .Values.global.domain_name }}
              |||,
            },
          })
          + application.spec.withSyncPolicy({ syncOptions+: ['Replace=true'] }),
  'cert-manager': createApplication({ name: 'cert-manager', namespace: 'cert-manager' })
                  + application.spec.withSources([
                    {
                      repoURL: 'https://charts.jetstack.io',
                      targetRevision: '1.13.3',
                      chart: 'cert-manager',
                      helm: {
                        values: |||
                          installCRDs: true
                          prometheus:
                            servicemonitor:
                              enabled: true
                        |||,
                      },
                    },
                    {
                      repoURL: 'https://charts.jetstack.io',
                      targetRevision: '0.5.0',
                      chart: 'cert-manager-csi-driver',
                    },
                    {
                      repoURL: defaults.repoURL,
                      path: '%s/cert-manager' % defaults.path,
                      targetRevision: 'HEAD',
                    },
                  ]),
  'external-dns': createApplication({ name: 'external-dns', namespace: 'external-dns' }),
  'ingress-nginx': createApplication({ name: 'ingress-nginx', namespace: 'ingress-nginx' })
                   + application.spec.withSource(
                     {
                       repoURL: 'https://kubernetes.github.io/ingress-nginx',
                       targetRevision: '4.8.3',
                       chart: 'ingress-nginx',
                       helm: {
                         values: |||
                           controller:
                             allowSnippetAnnotations: true
                             service:
                               ipFamilyPolicy: RequireDualStack
                               internal:
                                 ipFamilyPolicy: RequireDualStack
                             ingressClassResource:
                               default: true
                             metrics:
                               enabled: true
                               serviceMonitor:
                                 enabled: true
                             config:
                               enable-real-ip: true
                               proxy-buffer-size: "16k"
                               proxy-buffers-number: 8
                         |||,
                       },
                     }
                   ),
  'kube-prometheus-stack': createApplication({ name: 'kube-prometheus-stack', namespace: 'kube-prometheus-stack' })
                           + application.spec.withSource(
                             {
                               repoURL: 'https://prometheus-community.github.io/helm-charts',
                               targetRevision: '56.2.1',
                               chart: 'kube-prometheus-stack',
                               helm: {
                                 values: |||
                                   alertmanager:
                                     enabled: false
                                   grafana:
                                     enabled: false
                                   kubeProxy:
                                     enabled: false
                                 |||,
                               },
                             }
                             + application.spec.withSyncPolicy({ syncOptions+: ['Replace=true'] }),
                           ),
  longhorn: createApplication({ name: 'longhorn', namespace: 'longhorn-system' })
            + application.spec.withSource(
              {
                repoURL: 'https://charts.longhorn.io',
                targetRevision: '1.5.3',
                chart: 'longhorn',
                helm: {
                  values: |||
                    persistence:
                      defaultDataLocality: best-effort
                      reclaimPolicy: Retain
                    defaultSettings:
                      backupTarget: "s3://0de979bf-e7f8-43f9-bd7b-d6a697483c6d@s3.eu-central-003.backblazeb2.com/"
                      backupTargetCredentialSecret: backblaze
                      backupstorePollInterval: 0
                      replicaSoftAntiAffinity: true
                      replicaAutoBalance: best-effort
                      defaultDataLocality: best-effort
                      orphanAutoDeletion: true
                      snapshotDataIntegrityImmediateCheckAfterSnapshotCreation: true
                      guaranteedInstanceManagerCPU: 6
                      concurrentAutomaticEngineUpgradePerNodeLimit: 1
                  |||,
                },
              }
            ),
  metallb: createApplication({ name: 'metallb', namespace: 'metallb-system' })
           + application.spec.withSources([
             {
               repoURL: 'https://metallb.github.io/metallb',
               targetRevision: '0.14.2',
               chart: 'metallb',
               helm: {
                 values: |||
                   speaker:
                     enabled: false
                   prometheus:
                     serviceAccount: kube-prometheus-stack-prometheus
                     namespace: kube-prometheus-stack
                     serviceMonitor:
                       enabled: true
                 |||,
               },
             },
             {
               repoURL: defaults.repoURL,
               path: '%s/metallb' % defaults.path,
               targetRevision: 'HEAD',
             },
           ]),
  vault: createApplication({ name: 'vault', namespace: 'vault' })
         + application.spec.withSource(
           {
             repoURL: 'https://helm.releases.hashicorp.com',
             targetRevision: '0.27.0',
             chart: 'vault',
             helm: {
               values: |||
                 server:
                   ha:
                     replicas: 1
                     enabled: true
                     raft:
                       enabled: true
                   ingress:
                     ingressClassName: nginx
                     enabled: true
                     annotations:
                       cert-manager.io/cluster-issuer: letsencrypt-prod
                       external-dns.alpha.kubernetes.io/hostname: vault.{{ .Values.global.domain_name }}
                     hosts:
                       - host: vault.{{ .Values.global.domain_name }}
                     tls:
                       - secretName: vault-{{ .Values.global.domain_name | replace "." "-" }}-cert
                         hosts:
                           - vault.{{ .Values.global.domain_name }}
                   dataStorage:
                     size: 256Mi
                     storageClass: longhorn
                 ui:
                   enabled: true
                 csi:
                   enabled: true
               |||,
             },
           }
         ),
  keycloakx: createApplication({ name: 'keycloakx', namespace: 'keycloakx' })
             + application.spec.withSource({
               repoURL: 'https://codecentric.github.io/helm-charts',
               targetRevision: '2.3.0',
               chart: 'keycloakx',
               helm: {
                 values: |||
                   args:
                     - "start"
                     - "--http-enabled=true"
                     - "--http-port=8080"
                     - "--hostname-strict=false"
                     - "--hostname-strict-https=false"
                     - "--proxy=edge"
                     - "--db-password=$(cat /vault/secrets/keycloak)"
                   resources:
                     requests:
                       memory: "256Mi"
                     limits:
                       cpu: "250m"
                       memory: "512Mi"
                   ingress:
                     enabled: true
                     ingressClassName: "nginx"
                     annotations:
                       cert-manager.io/cluster-issuer: "letsencrypt-prod"
                       external-dns.alpha.kubernetes.io/hostname: "auth.arleskog.se"
                       nginx.ingress.kubernetes.io/proxy-buffer-size: "128k"
                       {{- with .Values.keycloakx.ingressAnnotations }}
                       nginx.ingress.kubernetes.io/server-snippet: {{ toYaml .serverSnippet | indent 12 }}
                       {{- end }}
                     rules:
                       - host: auth.arleskog.se
                         paths:
                           - path: /realms/
                             pathType: Prefix
                           - path: /resources/
                             pathType: Prefix
                           - path: /robots.txt
                             pathType: Prefix
                           - path: /js/
                             pathType: Prefix
                     tls:
                       - hosts:
                           - auth.arleskog.se
                         secretName: auth-arleskog-se-cert
                   http:
                     relativePath: "/"
                   podAnnotations:
                     vault.hashicorp.com/agent-inject: 'true'
                     vault.hashicorp.com/role: 'keycloak'
                     vault.hashicorp.com/agent-inject-secret-keycloak: 'keycloak'
                     {{- with .Values.keycloakx.podAnnotations }}
                     vault.hashicorp.com/agent-inject-template-keycloak: {{ toYaml .agentInjectTemplateKeycloak | indent 10 }}
                     {{- end }}
                   extraEnv: |
                     - name: KEYCLOAK_ADMIN
                       value: admin
                     - name: JAVA_OPTS
                       value: >-
                         -XX:+UseContainerSupport
                         -XX:MaxRAMPercentage=75.0
                         -Djava.awt.headless=true
                         -Djgroups.dns.query=keycloak-headless
                   serviceAccount:
                     create: true
                   service:
                     annotations:
                       prometheus.io/scrape: "true"
                       prometheus.io/port: "8080"
                   dbchecker:
                     enabled: true
                   database:
                     vendor: postgres
                     username: keycloak
                     database: keycloak
                     hostname: postgresql.db.svc.cluster.local
                     port: 5432
                 |||,
               },
             }),
  postgresql: createApplication({ name: 'postgresql', namespace: 'db' })
              + application.spec.withSource({
                repoURL: 'https://charts.bitnami.com/bitnami',
                targetRevision: '12.5.5',
                chart: 'postgresql',
                helm: {
                  values: |||
                    primary:
                      persistence:
                        size: 4Gi
                        storageClass: longhorn
                  |||,
                },
              }),
  gotify: createApplication({ name: "gotify", namespace: "gotify"}),
  wikijs: createApplication({ name: "wikijs", namespace: "wikijs" }),
  blocky: createApplication({ name: "blocky", namespace: "blocky" })
};

{
  ['%s/%s.json' % [app, manifest.key]]: std.toString(manifest.value)
  for app in std.objectFields(root)
  for manifest in std.objectKeysValues(root[app])
} + {
  ['templates/%s.yaml' % app]: std.toString(std.manifestYamlDoc(applications[app], indent_array_in_object=true, quote_keys=false))
  for app in std.objectFields(applications)
}
