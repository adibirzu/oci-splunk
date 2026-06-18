Splunk App for OCI

For documentation, see details on Splunkbase.o

General instructions:
- Setup VCN summary index on indexer(s) with config below
- Install App on Search Heads (via deployer if SHC)
- Edit `oci_index` macro with the indexed setup earlieer
- Install OCI Log Streaming add-on on a Splunk 8.0+ Heavy Forwarder
- Create inputs through the add-on configuration screen. If you happen to edit inputs through the standard Splunk inputs UI, be sure to presever 'oci_streaming' as the sourcetype. The add-on includes props and transforms to reassign the sourcetype based on the 'type' field.
- Once you have respective data come in, you may need to run all the saved searched ending with 'RUN ONCE' to have lookups populated. There are other saved searches that run every 15 minutes and look for new items from recent events and update lookups, but they will not go back beyond 15 minutes. The 'RUN ONCE' saved searches address this and look back to earliest=1 time. If you need to cleanup the lookups and tempted to run the 'RUN ONCE' saved searches down the road, use caution. Possibly update the earliest line to minimize the search run time.
- Dashboards should populate once the saved searches populating the lookups are executed and you have data flowing in.

[oci_vcn_summary]
coldToFrozenDir = $SPLUNK_DB/oci_vcn_summary/frozendb
coldPath = $SPLUNK_DB/oci_vcn_summary/colddb
homePath = $SPLUNK_DB/oci_vcn_summary/db
thawedPath = $SPLUNK_DB/oci_vcn_summary/thaweddb

# frozen time is 7 days
frozenTimePeriodInSecs = 604800
maxHotIdleSecs = 3600

repFactor = auto
