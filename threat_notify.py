#!/usr/bin/env python

from elasticsearch6 import Elasticsearch
from socket import gethostname
from time import sleep
import json
import pprint
import salt.client

whoami = gethostname()
alert = salt.client.Caller()
pp = pprint.PrettyPrinter(indent=4)
es = Elasticsearch([{'host':'localhost','port':9200}])

S = [ "device", "rule_name", "action", "application", "severity", "threat_type", "rule_name", "rule_name", "src_ip", "dst_ip", "dst_port" ]

Q = {
    "query": {
        "bool": {
          "must": [
            { "terms": {"action": ["deny", "drop", "reset-client", "reset-server", "reset-both", "block-url", "block-ip", "random-drop", "sinkhole", "block"]} },
            { "range": {
              "@timestamp": {
                "gte": "now-1h",
                "lte": "now"
              }
            }}
          ]
        }
    }
}


def _send_alert(M):
    alert.sminion.functions['event.send'](
            'salt/{}/slack'.format(whoami),
            {
                "message": M,
            }
    )

giveme = es.search(index='pathreats-*', size=1000, _source=S, body=Q)

if giveme['hits']['total'] > 0:
  data = {}
  for hit in giveme['hits']['hits']:
    fp = hash(json.dumps(hit['_source']))
    if fp not in data:
      data[fp] = hit['_source']
else:
  print "No data"
  exit(0)

struct = {}
for K,V in data.iteritems():
  ship = "{} {} -> {}:{} {}".format(V['action'], V['src_ip'], V['dst_ip'], V['dst_port'], V['application'])
  if V['device'] not in struct:
    struct[V['device']] = {V['rule_name']:[ship]}
  elif V['rule_name'] not in struct[V['device']]:
    struct[V['device']][V['rule_name']] = [ship]
  else:
    struct[V['device']][V['rule_name']].append(ship)
print struct

for fw,rule in struct.iteritems():
  for r,V in rule.iteritems():
    msg = "notifications for {} policy {}".format(fw, r)
    _send_alert(msg)
    sleep(10)
    for v in V:
      _send_alert(v)
      print v
      sleep(5) 
