# Verification run — 2026-08-07

Captured against the live lab. Commands are from `implementation.md` §5.

## Karpenter: three pools, and pool 3 at 1 On-Demand : 3 Spot
```
NAME                      NODECLASS   NODES   READY   AGE
general-spot-amd64        default     4       True    20m
graviton-arm64            default     2       True    20m
microservices-on-demand   default     1       True    20m
microservices-spot        default     3       True    20m

ip-10-0-10-144.ap-southeast-1.compute.internal   Ready   <none>   8m53s   v1.36.2-eks-254016e   spot        t3.small
ip-10-0-10-71.ap-southeast-1.compute.internal    Ready   <none>   8m47s   v1.36.2-eks-254016e   on-demand   t3a.small
ip-10-0-11-110.ap-southeast-1.compute.internal   Ready   <none>   8m52s   v1.36.2-eks-254016e   spot        t3.small
ip-10-0-11-201.ap-southeast-1.compute.internal   Ready   <none>   8m50s   v1.36.2-eks-254016e   spot        t3.small
```

## Pod placement: each service on its own pool, no two replicas sharing a node
```
frontend-7b46bb7d78-7hz67    ip-10-0-10-216.ap-southeast-1.compute.internal
frontend-7b46bb7d78-87nmd    ip-10-0-11-232.ap-southeast-1.compute.internal
frontend-7b46bb7d78-v7dtf    ip-10-0-10-99.ap-southeast-1.compute.internal
frontend-7b46bb7d78-wwv2b    ip-10-0-11-75.ap-southeast-1.compute.internal
inventory-6f4f8cbcf5-5wbc5   ip-10-0-11-157.ap-southeast-1.compute.internal
inventory-6f4f8cbcf5-5xtwk   ip-10-0-10-48.ap-southeast-1.compute.internal
load                         ip-10-0-11-86.ap-southeast-1.compute.internal
orders-bddfbc98d-7zttg       ip-10-0-11-110.ap-southeast-1.compute.internal
orders-bddfbc98d-k5fbf       ip-10-0-11-201.ap-southeast-1.compute.internal
orders-bddfbc98d-q5s9n       ip-10-0-10-144.ap-southeast-1.compute.internal
orders-bddfbc98d-ssgcq       ip-10-0-10-71.ap-southeast-1.compute.internal
```

## Managed node group hosts infrastructure only (no `sample` namespace)
```
      5 argocd
      3 external-secrets
      1 karpenter
      3 keda
     16 kube-system
     10 monitoring
      1 sample
```

## EFS-backed PersistentVolume, dynamically provisioned
```
NAME      PROVISIONER       RECLAIMPOLICY   VOLUMEBINDINGMODE   ALLOWVOLUMEEXPANSION   AGE
efs-rwx   efs.csi.aws.com   Delete          Immediate           true                   20m
NAME                        STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
sample-microservices-data   Bound    pvc-427d3208-af34-441d-8306-e088a6cc9f21   1Gi        RWX            efs-rwx        <unset>                 9m23s
```

## Topology spread + pod anti-affinity (orders)
```
{"podAntiAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":[{"labelSelector":{"matchLabels":{"app.kubernetes.io/component":"orders","app.kubernetes.io/instance":"sample-microservices","app.kubernetes.io/name":"sample-microservices"}},"topologyKey":"kubernetes.io/hostname"}]}}
```

## Argo CD is the only delivery path
```
$ helm --kube-context eks-workload list -A | grep sample
sample-microservices-app  	argocd          	1       	2026-08-07 04:39:18.0943648 +0700 +07	deployed	sample-microservices-app-0.1.0  	           

# the workloads in `sample` are owned by Argo CD, not Helm:
NAME                   SYNC STATUS   HEALTH STATUS
sample-microservices   Synced        Healthy
```

## KEDA autoscaling (under load), holding across Argo CD reconciles
```
NAME                            SCALETARGETKIND      SCALETARGETNAME   MIN   MAX   READY   ACTIVE   FALLBACK   PAUSED    TRIGGERS   AUTHENTICATIONS   AGE
scaledobject.keda.sh/frontend   apps/v1.Deployment   frontend          2     4     True    True     False      Unknown                                9m44s

NAME                                                    REFERENCE             TARGETS         MINPODS   MAXPODS   REPLICAS   AGE
horizontalpodautoscaler.autoscaling/keda-hpa-frontend   Deployment/frontend   3566m/5 (avg)   2         4         4          9m44s
frontend   4
```

## Single Secrets Manager secret, synced by ESO into both clusters
```
$ aws secretsmanager list-secrets --query "SecretList[].Name"
plutus/secrets	eks-lab

NAMESPACE    NAME                       STORETYPE            STORE         REFRESH INTERVAL   STATUS         READY   LAST SYNC
argocd       argocd-admin-password      ClusterSecretStore   aws-secrets   1h                 SecretSynced   True    13m
monitoring   javamelody-auth            ClusterSecretStore   aws-secrets   1h                 SecretSynced   True    13m
sample       javamelody-collector-url   ClusterSecretStore   aws-secrets   1h                 SecretSynced   True    13m
NAMESPACE    NAME            STORETYPE            STORE         REFRESH INTERVAL   STATUS         READY   LAST SYNC
monitoring   grafana-admin   ClusterSecretStore   aws-secrets   1h                 SecretSynced   True    13m
```

## Telemetry reaching cluster 2

Metrics — targets carrying `cluster="eks-workload"` inside the *central* Prometheus:
```
{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[1786053561.252,"77"]}]}}
{"status":"success","data":["eks-workload"]}

{"traces":[{"traceID":"5be4b5773cdcf0b97416c95972bfbc2","rootServiceName":"inventory","rootTraceName":"GET /readyz","startTimeUnixNano":"1786053008026251305"},{"traceID":"5f1142751b964d6607156e699e890be1","rootServiceName":"frontend","rootTraceName":"GET /healthz","startTimeUnixNano":"1786053007771158142"}],"metrics":{"inspectedTraces":8,"inspectedBytes":"17933","completedJobs":1,"totalJobs":1}}{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[1786053561.252,"77"]}]}}
```

## JavaMelody: the collector aggregates all four `orders` JVMs
```
orders-bddfbc98d-7zttg
orders-bddfbc98d-k5fbf
orders-bddfbc98d-q5s9n
orders-bddfbc98d-ssgcq
```

---

# Second pass — three JVM services, open API endpoints

## Public API access (now open; still IAM-authenticated)
```
eks-workload         0.0.0.0/0
eks-observability    0.0.0.0/0
```

## Four services; three are JVM, spread across all three pools
```
      2 frontend -> general/spot/amd64
      2 inventory -> graviton/spot/arm64
      1 orders -> mixed/on-demand/amd64
      3 orders -> mixed/spot/amd64
      2 payments -> general/spot/amd64

pods: 10   distinct nodes: 8   (equal => anti-affinity holding)
```

## JavaMelody aggregates every Java app
```
orders    -> 4 JVM nodes registered
inventory -> 2 JVM nodes registered
payments  -> 2 JVM nodes registered
```

## Argo CD
```
NAME                   SYNC STATUS   HEALTH STATUS
sample-microservices   Synced        Healthy
```
