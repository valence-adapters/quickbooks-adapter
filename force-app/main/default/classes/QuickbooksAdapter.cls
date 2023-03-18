/*
MIT License


Copyright (c) 2018 Valence Salesforce Integration Extensions

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

/**
 * Open-source Valence Adapter (https://valence.app) designed to talk to the Quickbooks Online API.
 *
 * @see https://docs.valence.app
 * @see https://developer.intuit.com/app/developer/qbo/docs/get-started
 *
 * Schema info is pulled from copies of two JSON files that are stored as static resources, and were originally pulled from:
 * https://static.developer.intuit.com/JSONObjects/EntityJsonObject_v1.json
 * https://static.developer.intuit.com/JSONObjects/CodesModelsJsonObjects_v1.json
 */
global with sharing class QuickbooksAdapter implements valence.NamedCredentialAdapter, valence.ConfigurableSourceAdapter, valence.ConfigurableTargetAdapter, valence.SchemaAdapter, valence.SourceAdapterScopeSerializer, valence.TargetAdapter {

	/**
	 * The expected datetime formatting that the API needs for Datetime literals (ISO 8601)
	 */
	public final static String API_DATETIME_FORMAT = 'yyyy-MM-dd\'T\'HH:mm:ssXXX';
	public final static String API_MINOR_VERSION = '63';
	public final static Set<String> OPERATIONS_REQUIRING_SYNC_TOKEN = new Set<String>{'update', 'delete'};
	public final static Integer MAX_PAGE_SIZE = 1000;

	private String realmId;

	@TestVisible
	private String namedCredentialName = null;

	private TargetConfiguration targetConfig = null;

	// ----------------------------------
	// ----- NamedCredentialAdapter -----
	// ----------------------------------

	public void setNamedCredential(String namedCredentialName) {
		this.namedCredentialName = namedCredentialName;
	}

	// -------------------------
	// ----- SchemaAdapter -----
	// -------------------------

	public List<valence.Table> getTables() {

		List<valence.Table> tables = new QuickbooksSchema().getTables(); // standard tables

		// specialty tables that represent specific functionality, such as sending an email
		tables.add(
			valence.Table.create('SendInvoice')
				.withLabel('Send Invoice')
				.withDescription('Write to this "table" to tell QBO to email this invoice to the billing email addresses it has on file.')
				.setEditable(true)
				.setReadable(false)
				.build()
		);

		return tables;
	}

	public List<valence.Field> getFields(String tableApiName) {

		switch on tableApiName {

			when 'SendInvoice' {
				return new List<valence.Field>{
					valence.Field.create('Id')
						.setRequired(true)
						.withDescription('Unique identifier for this object.')
						.withType('String')
						.build()
				};
			}

			when else {
				return new QuickbooksSchema().getFields(tableApiName);
			}
		}
	}

	// --------------------------------
	// ----- SourceAdapterForPull -----
	// --------------------------------

	public valence.FetchStrategy planFetch(valence.LinkContext context) {

		// calculate actual page size to use
		Integer pageSize = context.batchSizeLimit < MAX_PAGE_SIZE ? context.batchSizeLimit : MAX_PAGE_SIZE;

		// count the number of records we need to fetch
		Integer count = queryAPI(buildCountQuery(context.linkSourceName, context.lastSuccessfulSync)).get('QueryResponse.totalCount').getIntegerValue();

		if(count == 0) {
			return valence.FetchStrategy.noRecords();
		}
		else if(count < pageSize) {
			return valence.FetchStrategy.immediate(count);
		}
		else {
			List<FetchScope> scopes = new List<FetchScope>();
			Integer offset = 1;
			while(offset <= count) {
				scopes.add(new FetchScope(offset, pageSize));
				offset += pageSize;
			}
			return valence.FetchStrategy.scopes(scopes, count);
		}
	}

	public List<valence.RecordInFlight> fetchRecords(valence.LinkContext context, Object scope) {

		FetchScope fetchScope = (FetchScope)scope;

		List<valence.RecordInFlight> records = new List<valence.RecordInFlight>();

		valence.JSONParse response = queryAPI(buildQuery(
			context.linkSourceName,
			fetchScope != null ? fetchScope.startPosition : 1,
			fetchScope != null ? fetchScope.maxRecords : MAX_PAGE_SIZE,
			context.lastSuccessfulSync,
			null,
			false
		));

		System.debug(LoggingLevel.WARN, response.toStringPretty());

		for(valence.JSONParse item : response.get('QueryResponse.' + context.linkSourceName).asList()) {
			records.add(new valence.RecordInFlight((Map<String, Object>)item.getValue()));
		}

		return records;
	}

	// -------------------------
	// ----- TargetAdapter -----
	// -------------------------

	public Integer getBatchSizeLimit(valence.LinkContext context) {
		return 30; // Intuit has a limit of 30 items per invocation of their batch endpoint
	}

	public void pushRecords(valence.LinkContext context, List<valence.RecordInFlight> records) {

		// don't write anything if we're in testing mode
		if(context.testingMode == true) {
			return;
		}

		// sending invoices to customers follows a different flow
		if('SendInvoice'.equalsIgnoreCase(context.linkTargetName)) {
			sendInvoiceEmails(records);
		}

		/*
		 * We collect Quickbooks IDs for anything we need to update so we can fetch SyncToken values.
		 */
		List<String> quickbookIds = new List<String>();
		for(valence.RecordInFlight record : records) {
			if(record.hasProperty('Id', true)) {
				quickbookIds.add((String)record.getPropertyValue('Id'));
			}
		}

		/*
		 * Quickbooks requires a "SyncToken" value to be passed for any updates to prove that you were changing the most recent version. For
		 * any updates we intend to make, we'll fetch these and use them in our update payloads.
		 */
		Map<String, String> syncTokens = new Map<String, String>();
		if(!quickbookIds.isEmpty()) {
			valence.JSONParse response = queryAPI(buildSyncTokenQuery(context.linkTargetName, quickbookIds)).get('QueryResponse');
			if(response.exists(context.linkTargetName, true)) {
				for(valence.JSONParse item : response.get(context.linkTargetName).asList()) {
					syncTokens.put(item.get('Id').getStringValue(), item.get('SyncToken').getStringValue());
				}
			}
		}

		/*
		 * Now that we have syncTokens, build a representation of each record that needs to go to Quickbooks
		 */
		List<Map<String, Object>> items = new List<Map<String, Object>>();
		for(valence.RecordInFlight record : records) {
			items.add(buildBatchItem(context.linkTargetName, record, syncTokens));
		}

		HttpRequest req = buildBatchRequest(items);

		System.debug(LoggingLevel.WARN, req.getBody());

		HttpResponse res = new Http().send(req);

		System.debug(LoggingLevel.WARN, res.getStatusCode() + ':' + res.getStatus());
		System.debug(LoggingLevel.WARN, res.getBody());

		checkForHttpErrors(res);

		List<valence.JSONParse> responses = new valence.JSONParse(res.getBody()).get('BatchItemResponse').asList();
		List<SObject> writebacks = new List<SObject>();
		WritebackHelper helper = new WritebackHelper();
		for(Integer i = 0, j = responses.size(); i < j; i++) {
			Boolean success = applyResponse(context.linkTargetName, responses[i], records[i]);
			/*
			 * If we successfully wrote to Quickbooks, update the record in Salesforce with its Quickbooks unique identifier
			 */
			if(success == true && !'delete'.equalsIgnoreCase(records[i].getOperation())) {
				writebacks.addAll(calculateWritebacks(helper, context, responses[i].get(context.linkTargetName), records[i]));
			}
		}

		if(!writebacks.isEmpty()) {
			writebacks.sort(); // sorting arranges by SObjectType so we don't get into trouble with DML chunking
			System.debug('-- WRITEBACKS --');
			for(SObject obj : writebacks) {
				System.debug(obj);
			}

			List<SObject> filtered = new List<SObject>();
			for(SObject obj : writebacks) {
				if(helper.isDifferent(obj)) {
					filtered.add(obj);
				}
			}
			System.debug('-- FILTERED WRITEBACKS --');
			for(SObject obj : filtered) {
				System.debug(obj);
			}
			if(!filtered.isEmpty()) {
				update filtered;
			}
		}
	}

	private List<SObject> calculateWritebacks(WritebackHelper helper, valence.LinkContext context, valence.JSONParse response, valence.RecordInFlight record) {

		List<SObject> writebacks = new List<SObject>();

		Type sourceType = Type.forName(context.linkSourceName);
		SObject original = (SObject)sourceType.newInstance();
		original.put('Id', record.getOriginalPropertyValue('Id'));
		Boolean originalHasContent = false;
		for(PathPair pair : targetConfig.mainPairs) {
			original.put(pair.sf, response.get(pair.qbo).getValue());
			originalHasContent = true;
			helper.trackField(context.linkSourceName, pair.sf);
		}
		if(originalHasContent == true && original.isSet('Id')) {
			writebacks.add(original);
			helper.trackId(context.linkSourceName, (String)original.get('Id'));
		}

		/*
		 * Each configuration for an inner list is its own self-contained thing, which we process here and add to our writebacks.
		 */
		for(ListWriteback nested : targetConfig.listPairs) {

			// note: the lengths of these arrays will typically not match, as Quickbooks likes to stick extra lines at the end of theirs for things like subtotals, etc
			List<Object> sfRecords = (List<Object>)record.getOriginalPropertyValue(nested.sfListFieldName);
			List<valence.JSONParse> responseRecords = response.get(nested.qboListFieldName).asList();

			Type listObjectType = Type.forName(nested.sfObjectName); // determine the type of SObject we will be building
			for(Integer i = 0, j = sfRecords.size(); i < j; i++) {
				SObject nestedObject = (SObject)listObjectType.newInstance();
				String idValue = String.valueOf(((Map<String, Object>)sfRecords[i]).get('Id'));
				nestedObject.put('Id', idValue);
				helper.trackId(nested.sfObjectName, idValue);
				for(PathPair pair : nested.pairs) {
					nestedObject.put(pair.sf, responseRecords[i].get(pair.qbo).getValue());
					helper.trackField(nested.sfObjectName, pair.sf);
				}
				writebacks.add(nestedObject);
			}
		}

		return writebacks;
	}

	private void sendInvoiceEmails(List<valence.RecordInFlight> records) {

		// tell QBO to send an invoice out to the customer; these must be done one per callout
		for(valence.RecordInFlight record : records) {
			if(record.hasProperty('Id')) {

				HttpRequest req = buildRequest('invoice/' + record.getPropertyValue('Id') + '/send', null);

				System.debug(LoggingLevel.WARN, req.getBody());

				HttpResponse res = new Http().send(req);

				System.debug(LoggingLevel.WARN, res.getStatusCode() + ':' + res.getStatus());
				System.debug(LoggingLevel.WARN, res.getBody());

				checkForHttpErrors(res);
			}
		}
	}

	// ----------------------------------------
	// ----- SourceAdapterScopeSerializer -----
	// ----------------------------------------

	public Object deserializeScope(String serializedScope) {
		return JSON.deserialize(serializedScope, FetchScope.class);
	}

	public String serializeScope(Object scope) {
		return JSON.serialize(scope);
	}

	// -------------------------------------
	// ----- ConfigurableSourceAdapter -----
	// -------------------------------------

	public String explainSourceConfiguration(valence.LinkContext context, String configData) {
		SourceConfiguration config = parseSourceConfig(configData);
		return String.format('<p>Using Realm ID <strong>{0}</strong>.</p>', new List<Object>{config.realmId});
	}

	public String getSourceConfigurationLightningComponent(valence.LinkContext context) {
		return null;
	}

	public String getSourceConfigurationStructure(valence.LinkContext context) {
		return null;
	}

	public void setSourceConfiguration(valence.LinkContext context, String configData) {
		SourceConfiguration sourceConfig = parseSourceConfig(configData);
		realmId = sourceConfig.realmId;
	}

	// -------------------------------------
	// ----- ConfigurableTargetAdapter -----
	// -------------------------------------

	public String explainTargetConfiguration(valence.LinkContext context, String configData) {
		TargetConfiguration config = parseTargetConfig(configData);
		Integer mainPairs = config.mainPairs?.size();
		Integer listPairs = config.listPairs?.size();
		return String.format('<p>Using Realm ID <strong>{0}</strong>.{1}{2}</p>', new List<Object>{
			config.realmId,
			mainPairs != null && mainPairs > 0 ? ' The main record will have ' + mainPairs + ' field' + (mainPairs > 1 ? 's' : '') + ' written back.' : '',
			listPairs != null && listPairs > 0 ? ' Also, ' + listPairs + ' nested list' + (mainPairs > 1 ? 's' : '') + ' will be written back to.' : ''
		});
	}

	public String getTargetConfigurationLightningComponent(valence.LinkContext context) {
		return 'c:quickbooksAdapterTargetConfigurator';
	}

	public String getTargetConfigurationStructure(valence.LinkContext context) {
		return null;
	}

	public void setTargetConfiguration(valence.LinkContext context, String configData) {
		targetConfig = parseTargetConfig(configData);
		realmId = targetConfig.realmId;
	}

	// -------------------
	// ----- Helpers -----
	// -------------------

	private valence.JSONParse queryAPI(String query) {

		HttpRequest req = buildQueryRequest(query);

		System.debug(LoggingLevel.WARN, 'Query: ' + query);

		HttpResponse res = new Http().send(req);

		System.debug(LoggingLevel.WARN, res.getStatusCode() + ':' + res.getStatus());
		System.debug(LoggingLevel.WARN, res.getBody());

		checkForHttpErrors(res);

		valence.JSONParse response = new valence.JSONParse(res.getBody());

		return response;
	}

	private static String buildCountQuery(String tableName, Datetime lastModified) {
		return buildQuery(tableName, 1, MAX_PAGE_SIZE, lastModified, null, true);
	}

	private static String buildSyncTokenQuery(String tableName, List<String> quickbookIds) {
		return buildQuery(tableName, 1, MAX_PAGE_SIZE, null, quickbookIds, true);
	}

	/**
	 * Build various Quickbooks-friendly queries. Examples:
	 *
	 * SELECT COUNT(*) FROM Customer
	 * SELECT * FROM Vendor WHERE Metadata.LastUpdatedTime >= 2021-01-22T16:59:06.692-1000
	 * SELECT Id, SyncToken FROM Invoice WHERE Id IN (32, 123)
	 *
	 * @param tableName The Quickbook table to query
	 * @param startPosition A record offset for pagination, starting at 1
	 * @param maxResults A page size for pagination
	 * @param lastModified A lastModified timestamp to filter records on
	 * @param quickbookIds A list of specific records to fetch when we're grabbing sync tokens
	 * @param count A flag for if we just want to count records
	 *
	 * @return A properly-formatted Quickbooks query
	 */
	@TestVisible
	private static String buildQuery(String tableName, Integer startPosition, Integer maxResults, Datetime lastModified, List<String> quickbookIds, Boolean count) {

		Boolean idQuery = quickbookIds != null && !quickbookIds.isEmpty();
		return String.format('SELECT {0} FROM {1}{2} startposition {3} maxresults {4}',
			new List<Object>{
				idQuery == true ? 'Id,SyncToken' : (count == true ? 'COUNT(*)' : '*'),
				tableName,
				idQuery == true ? ' WHERE Id IN (\'' + String.join(quickbookIds, '\',\'') + '\')' :
					(lastModified != null ? ' WHERE Metadata.LastUpdatedTime >= \'' + lastModified.format(API_DATETIME_FORMAT) + '\'' : ''),
				startPosition,
				maxResults
			}
		);
	}

	/**
	 * Convert a RecordInFlight into a shape that works for Quickbooks.
	 *
	 * @param entityName The QBO entity name
	 * @param record Details about the record
	 * @param syncTokens The latest SyncToken for each record, organized by Quickbooks Id
	 *
	 * @return A representation of this record that the Quickbooks Batch API will be happy to accept
	 */
	private static Map<String, Object> buildBatchItem(String entityName, valence.RecordInFlight record, Map<String, String> syncTokens) {

		String operation = 'delete'.equalsIgnoreCase(record.getOperation()) ? 'delete' : record.hasProperty('Id', true) ? 'update' : 'create';
		record.setOperation(operation); // adjust the record operation to be more specific
		if('update'.equalsIgnoreCase(operation)) {
			record.setPropertyValue('sparse', true); // we always do sparse updates; no admin is going to configure every single field as a mapping
		}
		Map<String, Object> payload = new Map<String, Object>{
			'operation' => operation,
			'bId' => record.getSalesforceId(),
			entityName => record.getProperties()
		};
		if(OPERATIONS_REQUIRING_SYNC_TOKEN.contains((String)payload.get('operation'))) {
			String syncToken = syncTokens.get((String)record.getPropertyValue('Id'));
			((Map<String, Object>)payload.get(entityName)).put('SyncToken', syncToken); // set our syncToken
			record.setPropertyValue('SyncToken', syncToken);
		}
		return payload;
	}

	private static Boolean applyResponse(String entityName, valence.JSONParse response, valence.RecordInFlight record) {
		Boolean success = true;
		if(response.get('bId').getStringValue() != record.getSalesforceId()) {
			record.addError('Response mismatch, response bId (' + response.get('bId').getStringValue() + ') does not match (' + record.getSalesforceId() + ').');
			success = false;
		}
		if(response.exists('Fault')) {
			valence.JSONParse fault = response.get('Fault');
			String errorMessage = fault.get('type').getStringValue() + ': ';
			for(valence.JSONParse error : fault.get('Error').asList()) {
				String thisError = ' [';
				if(error.exists('code')) {
					thisError += error.get('code').getStringValue() + ': ';
				}
				if(error.exists('Message')) {
					thisError += error.get('Message').getStringValue() + '; ';
				}
				if(error.exists('Detail')) {
					thisError += error.get('Detail').getStringValue() ;
				}
				if(error.exists('element')) {
					thisError += '(' + error.get('element').getStringValue() + ')';
				}
				errorMessage += thisError + '] ';
			}
			if('delete'.equalsIgnoreCase(record.getOperation())) { // problems deleting a record are bumped down to a warning, as it's possible they never existed or were already deleted
				record.addWarning(errorMessage);
			} else { // mark this record as unsuccessful
				record.addError(errorMessage);
				success = false;
			}
		}
		// save some details back to the RecordInFlight instance for reporting purposes
		if(response.exists(entityName)) {
			record.setPropertyValue('Id', response.get(entityName + '.Id').getStringValue());
		}
		record.setSuccess(success);
		record.setCreated('create'.equalsIgnoreCase(record.getOperation()));
		return success;
	}

	/**
	 * Build an HTTPRequest suitable for sending to the QBO batch endpoint.
	 *
	 * @param items Items to be sent for writing
	 *
	 * @return A request ready to send
	 */
	private HttpRequest buildBatchRequest(List<Object> items) {
		HttpRequest req = buildRequest('batch', JSON.serializePretty(new Map<String, Object>{
			'BatchItemRequest' => items
		}));
		req.setHeader('Content-Type', 'application/json');
		return req;
	}

	/**
	 * Build an HTTPRequest suitable for reading from the QBO query endpoint.
	 *
	 * @param query The query to use
	 *
	 * @return A request ready to send
	 */
	private HttpRequest buildQueryRequest(String query) {
		return buildRequest('query', query);
	}

	/**
	 * Simple helper method for building HTTPRequest instances that are appropriately configured.
	 *
	 * @param partialUrl A sub-resource within the API to access
	 * @param body The body of the payload that will be sent to the API
	 *
	 * @return A request, ready to be sent
	 */
	@TestVisible
	private HttpRequest buildRequest(String partialUrl, String body) {

		HttpRequest req = new HttpRequest();
		req.setMethod('POST');
		req.setTimeout(120000);
		req.setHeader('Accept', 'application/json');
		req.setHeader('Accept-Encoding', 'gzip');
		req.setHeader('Content-Type', 'application/text');
		req.setCompressed(true);
		req.setEndpoint('callout:' + namedCredentialName + '/v3/company/' + realmId + '/' + partialUrl + '?minorversion=' + API_MINOR_VERSION);
		req.setBody(body);
		return req;
	}

	/**
	 * Check for errors at the transport layer of an HTTP response.
	 *
	 * @param response The response from the Quickbooks API
	 */
	private void checkForHttpErrors(HttpResponse response) {
		if(response.getStatusCode() < 200 || response.getStatusCode() >= 300) {
			throw new valence.AdapterException(response.getStatusCode() + ':' + response.getStatus() + '\n ' + response.getBody());
		}
	}

	private static SourceConfiguration parseSourceConfig(String configData) {
		if(String.isNotBlank(configData)) {
			return (SourceConfiguration)JSON.deserialize(configData, SourceConfiguration.class);
		}
		else {
			return new SourceConfiguration();
		}
	}

	private static TargetConfiguration parseTargetConfig(String configData) {
		if(String.isNotBlank(configData)) {
			return (TargetConfiguration)JSON.deserialize(configData, TargetConfiguration.class);
		}
		else {
			return new TargetConfiguration();
		}
	}

	private virtual class Configuration {

		private String realmId;
	}

	private class SourceConfiguration extends Configuration {

	}

	/**
	 * Simple class for holding the configuration needed when writing to the external API.
	 */
	private class TargetConfiguration extends Configuration {

		private List<PathPair> mainPairs;
		private List<ListWriteback> listPairs;
	}

	private class ListWriteback {

		String qboListFieldName;
		String sfListFieldName;
		String sfObjectName;

		List<PathPair> pairs;
	}

	private class PathPair {

		String qbo;
		String sf;
	}

	private class FetchScope {
		Integer startPosition;
		Integer maxRecords;

		private FetchScope(Integer startPosition, Integer maxRecords) {
			this.startPosition = startPosition;
			this.maxRecords = maxRecords;
		}
	}

	/**
	 * Facilitates getting schema data from flat files stored in static resources.
	 */
	private class QuickbooksSchema {

		private Map<String, valence.JSONParse> tableReference = null;
		private Map<String, valence.JSONParse> fieldReference = null;

		private void loadTableReference() {
			if(tableReference == null) {
				// load the model data from the static resource json file
				tableReference = new valence.JSONParse(
					Test.isRunningTest() ? TEST_TABLES :
						new PageReference('/resource/quickbooksSchema/EntityJsonObject_v1.json').getContent().toString()
				).get('entities.qbo').asMap();
			}
		}

		private void loadFieldReference() {
			if(fieldReference == null) {
				// load the model data from the static resource json file
				fieldReference = new valence.JSONParse(
					Test.isRunningTest() ? TEST_FIELDS :
						new PageReference('/resource/quickbooksSchema/CodesModelsJsonObjects_v1.json').getContent().toString()
				).get('models.qbo').asMap();
			}
		}

		public List<valence.Table> getTables() {
			loadTableReference(); // read the static resource file that lists QBO entities

			List<valence.Table> tables = new List<valence.Table>();

			// iterate through the entities and build nice table representations of the ones that we can work with
			for(String tableName : tableReference.keySet()) {
				valence.JSONParse entity = tableReference.get(tableName);
				Boolean isReadable = entity.exists('operations.QUERY');
				Boolean isCreatable = entity.exists('operations.CREATE');
				Boolean isUpdatable = entity.exists('operations.UPDATE');
				tables.add(
					valence.Table.create(tableName)
						.withLabel(entity.get('title').getStringValue())
						.withDescription(entity.get('description').getStringValue())
						.setReadable(isReadable)
						.setCreateable(isCreatable)
						.setUpdateable(isUpdatable)
						.build()
				);
			}

			return tables;
		}

		public List<valence.Field> getFields(String tableName) {
			loadTableReference(); // read the static resource file that lists QBO entities

			// exchange the table name for the internal QBO name for the model of that entity
			String modelName = tableReference.get(tableName)?.get('model.$ref').getStringValue();

			if(modelName == null) {
				return null;
			}

			loadFieldReference(); // read the static resource file with all the QBO model definitions

			return parseModel(fieldReference.get(modelName));
		}

		private List<valence.Field> parseModel(valence.JSONParse model) {
			List<valence.Field> fields = new List<valence.Field>();
			if(model == null) {
				return fields;
			}

			Map<String, valence.JSONParse> properties = model.get('properties').asMap();
			for(String propertyName : properties.keySet()) {
				valence.JSONParse field = properties.get(propertyName);

				/*
				 * Quickbooks does a weird thing where their list-based fields actually have a suffix [0..n] that is not the actual property name on records.
				 * Here we strip that and also use its presence to determine if this is a list-based field or not.
				 */
				String strippedName = propertyName.substringBefore('[0..n]');

				valence.Field.FieldBuilder builder = valence.Field.create(strippedName.trim());
				if(field.exists('description')) {
					builder.withDescription(field.get('description').getStringValue());
				}
				if(field.exists('requiredFlag')) {
					builder.setRequired('Required'.equalsIgnoreCase(field.get('requiredFlag').getStringValue()));
				}
				if(field.exists('readOnly')) {
					builder.setEditable(field.get('readOnly').getBooleanValue() == false);
				}
				else {
					builder.setEditable(true);
				}
				if(field.exists('type')) {
					builder.withType(field.get('type').getStringValue());
				}
				if(field.exists('maxLen')) {
					builder.withFormat(field.get('maxLen').getStringValue());
				}
				if(field.exists('default')) {
					builder.withDefaultValue(field.get('default').getStringValue());
				}

				// determine if this is a list field by checking the existence of [..n] in its name
				builder.setList(strippedName != propertyName, false);

				// determine if this is a map field by checking for a $ref property
				if(field.exists('$ref')) {
					builder.setMap(true, false);
					// $ref may have multiple entries, meaning that various different shapes might be referenced; we merge their fields into one list
					for(valence.JSONParse ref : field.get('$ref').asList()) {
						// extract the model name from the $ref entry and use it to fetch a list of fields
						for(valence.Field child : parseModel(fieldReference.get(new List<String>(ref.asMap().keySet())[0]))) {
							builder.addChild(child);
						}
					}
				}

				// finally, build the Field instance
				fields.add(builder.build());
			}

			return fields;
		}
	}

	/**
	 * Utility class to encapsulate tracking what we need to know about writebacks, then querying for them, then comparing a given record.
	 */
	private class WritebackHelper {

		private Map<String, Set<String>> writebackObjectFields = new Map<String, Set<String>>();
		private Map<String, Set<Id>> writebackObjectIds = new Map<String, Set<Id>>();
		private Boolean recordsFetched = false;
		private Map<Id, SObject> existingRecords = new Map<Id, SObject>();

		private void trackField(String objectName, String fieldName) {
			if(!writebackObjectFields.containsKey(objectName)) {
				writebackObjectFields.put(objectName, new Set<String>());
			}
			writebackObjectFields.get(objectName).add(fieldName);
		}

		private void trackId(String objectName, String id) {
			if(!writebackObjectIds.containsKey(objectName)) {
				writebackObjectIds.put(objectName, new Set<Id>());
			}
			writebackObjectIds.get(objectName).add(id);
		}

		/**
		 * Test a potential writeback to see if it is different than what is in the database.
		 *
		 * @param candidate The writeback to test
		 *
		 * @return True if it is different, false if it is identical to what is already there
		 */
		private Boolean isDifferent(SObject candidate) {
			if(recordsFetched == false) {
				fetchRecords();
			}
			SObject existing = existingRecords.get((String)candidate.get('Id'));
			Map<String, Object> candidateProps = candidate.getPopulatedFieldsAsMap();
			for(String fieldName : candidateProps.keySet()) {
				if(candidate.get(fieldName) != existing.get(fieldName)) {
					return true;
				}
			}
			return false;
		}

		/**
		 * Get all the various SObjects out and put them in a one map by id value.
		 */
		private void fetchRecords() {
			System.debug(LoggingLevel.WARN, '--fetchRecords--');
			System.debug(LoggingLevel.WARN, writebackObjectFields);
			System.debug(LoggingLevel.WARN, writebackObjectIds);
			for(String objectName : writebackObjectFields.keySet()) {
				Set<Id> ids = writebackObjectIds.get(objectName);
				existingRecords.putAll(Database.query(String.format('SELECT {0} FROM {1} WHERE Id IN :ids', new List<Object>{
					String.join(new List<String>(writebackObjectFields.get(objectName)), ','),
					objectName
				})));
			}
			System.debug(LoggingLevel.WARN, 'existingRecords(' + existingRecords.size() + '): ' + existingRecords);
		}
	}

	private static final String TEST_TABLES = '{"entities":{"qbo":{"Customer":{"code":"Read0-response","description":"Acustomerisaconsumeroftheserviceorproductthatyourbusinessoffers.Anindividualcustomercanhaveanunderlyingnestedstructure,withaparentcustomer(thetop-levelobject)havingzeroormoresub-customersandjobsassociatedwithit.<ul><li>Sub-customerexamples:</li><ul><li>Membersofateamorleague:theteamitselfistheparentcustomerandthemembersaresub-customers.</li><li>Propertiesmanagedbyapropertymanagementcompany:themanagementcompanyistheparentcustomerandthepropertiesarethesub-customers.</li></ul><li>Jobexamples:</li><ul><li>Trackingakitchenremodel:thehomeowneristheparentcustomerandindividualkitchenremodeltasksarejobs.</li><li>Trackingcarrepairs:thecarowneristheparentcustomerandindividualcarrepairsarejobs.</li></ul></ul>UsetheCustomerresourcetocreateparentcustomerobjects,sub-customerobjects,andjobobjectsaccordingtoyourbusinessrequirements.Usethe<spanclass=\\"literal\\">ParentRef</span>and<spanclass=\\"literal\\">Job</span>attributesinthecustomerobjecttodesignatewhethertheobjectisaparent,nestedjobornestedsub-customer.<ul><li>First,createparentcustomerobjects:Set<spanclass=\\"literal\\">Job</span>to<spanclass=\\"literal\\">false</span>(default)anddonotdefine<spanclass=\\"literal\\">ParentRef</span>.</li><li>Then,createsub-customerandjobobjects:Set<spanclass=\\"literal\\">Job</span>to<spanclass=\\"literal\\">true</span>andset<spanclass=\\"literal\\">ParentRef</span>toreferenceparentcustomerobject.</li></ul>Goingforward,specifyanindividualparentcustomerobject,sub-customerobject,orjobobjectinsalestransactionsviathetransaction\'sCustomerRefattribute,basedonyourbusinessrequirements.SeeQuickBooksproductdocumentationformoreaboutsub-customersandjobs.","model":{"$ref":"customerresponse"},"model-header":"TheCustomerobject","operations":{"CREATE":[{"definition":{"Contenttype":"application/json","Operation":"POST/v3/company/<realmID>/customer","ProductionBaseURL":"https://quickbooks.api.intuit.com","SandboxBaseURL":"https://sandbox-quickbooks.api.intuit.com"},"description":"<p>The<spanclass=\\"literal\\">DisplayName</span>attributeoratleastoneof<spanclass=\\"literal\\">Title</span>,<spanclass=\\"literal\\">GivenName</span>,<spanclass=\\"literal\\">MiddleName</span>,<spanclass=\\"literal\\">FamilyName</span>,or<spanclass=\\"literal\\">Suffix</span>attributesisrequiredduringobjectcreate.</p>","name":"Createacustomer","sections":[{"code":"Create0-request","description":"<p>TheminimumelementstocreateaCustomerarelistedhere.</p>","model":{"$ref":"customerrequest"},"name":"RequestBody"},{"code":"Create0-response","description":"<p>ReturnsthenewlycreatedCustomerobject.</p>","name":"Returns"}]}],"QUERY":[{"definition":{"Contenttype":"text/plain","Operation":"GET/v3/company/<realmID>/query?query=<selectStatement>","ProductionBaseURL":"https://quickbooks.api.intuit.com","SandboxBaseURL":"https://sandbox-quickbooks.api.intuit.com"},"name":"Queryacustomer","sections":[{"code":"Query0-request","name":"SampleQuery"},{"code":"Query0-response","description":"Returnstheresultsofthequery.","name":"Returns"}]}],"READ":[{"definition":{"Operation":"GET/v3/company/<realmID>/customer/<customerId>","ProductionBaseURL":"https://quickbooks.api.intuit.com","SandboxBaseURL":"https://sandbox-quickbooks.api.intuit.com"},"description":"RetrievesthedetailsofaCustomerobjectthathasbeenpreviouslycreated.","name":"Readacustomer","sections":[{"code":"Read0-response","description":"<p>ReturnstheCustomerobject.</p>","name":"Returns"}]}],"UPDATE":[{"definition":{"Contenttype":"application/json","Operation":"POST/v3/company/<realmID>/customer","ProductionBaseURL":"https://quickbooks.api.intuit.com","SandboxBaseURL":"https://sandbox-quickbooks.api.intuit.com"},"description":"UsethisoperationtoupdateanyofthewritablefieldsofanexistingCustomerobject.Therequestbodymustincludeallwritablefieldsoftheexistingobjectasreturnedinareadresponse.WritablefieldsomittedfromtherequestbodyaresettoNULL.TheIDoftheobjecttoupdateisspecifiedintherequestbody.Addthequeryparameter,<spanclass=\\"literal\\">include=updateaccountontxns&minorversion=5</span>,totheendpointtoautomaticallyupdatetheARaccountonhistoricaltransactions(fromsoftclosedateforward)forthiscustomerwiththatdefinedbythe<spanclass=\\"literal\\">ARAccountRef</span>attributeintheCustomerobject.Updatesonsoftclosedtransacitonswillfail.","name":"Fullupdateacustomer","sections":[{"code":"Update0-request","model":{"$ref":"customerresponse"},"name":"RequestBody"},{"code":"Update0-response","description":"Thecustomerresponsebody.","name":"Returns"}]},{"definition":{"Contenttype":"application/json","Operation":"POST/v3/company/<realmID>/customer","ProductionBaseURL":"https://quickbooks.api.intuit.com","SandboxBaseURL":"https://sandbox-quickbooks.api.intuit.com"},"description":"Sparseupdatingprovidestheabilitytoupdateasubsetofpropertiesforagivenobject;onlyelementsspecifiedintherequestareupdated.Missingelementsareleftuntouched.TheIDoftheobjecttoupdateisspecifiedintherequestbody.\\u200b","name":"Sparseupdateacustomer","sections":[{"code":"Update1-request","model":{"$ref":"customerresponse"},"name":"RequestBody"},{"code":"Update1-response","description":"Thecustomerresponsebody.","name":"Returns"}]}]},"optional-description":{"description":"<ul><li>The<spanclass=\\"literal\\">DisplayName</span>,<spanclass=\\"literal\\">Title</span>,<spanclass=\\"literal\\">GivenName</span>,<spanclass=\\"literal\\">MiddleName</span>,<spanclass=\\"literal\\">FamilyName</span>,<spanclass=\\"literal\\">Suffix</span>,and<spanclass=\\"literal\\">PrintOnCheckName</span>attributesmustnotcontaincolon(:),tab(\\\\t),ornewline(\\\\n)characters.</li><li>The<spanclass=\\"literal\\">DisplayName</span>attributemustbeuniqueacrossallothercustomer,employee,andvendorobjects.</li><li>The<spanclass=\\"literal\\">PrimaryEmailAddress</span>attributemustcontainanatsign(@)anddot(.).</li><li>NestedCustomerobjectscanbeusedtodefinesub-customers,jobs,oracombinationofboth,underaparent.</li><li>Uptofourlevelsofnestingcanbedefinedunderatop-levelparentCustomerobject.</li><li>The<spanclass=\\"literal\\">Job</span>attributedefineswhethertheobjectisaparentcustomerornestedsub-customer/job.</li><li>The<spanclass=\\"literal\\">DisplayName</span>attributeoratleastoneof<spanclass=\\"literal\\">Title</span>,<spanclass=\\"literal\\">GivenName</span>,<spanclass=\\"literal\\">MiddleName</span>,<spanclass=\\"literal\\">FamilyName</span>,or<spanclass=\\"literal\\">Suffix</span>attributesisrequiredduringobjectcreate.</li></ul>","heading":"BusinessRules"},"title":"Customer"}}}}';
	private static final String TEST_FIELDS = '{"models":{"qbo":{"customerresponse":{"name":"customerresponse","ShowFirst":["Id"],"Default":["TaxExemptionReasonId"],"Optional":["PrimaryEmailAddr","ResaleNum","ARAccountRef","DefaultTaxCodeRef","PreferredDeliveryMethod","GSTIN","SalesTermRef","FullyQualifiedName","Fax","BusinessNumber","BillWithParent","CurrencyRef","Mobile","Job","BalanceWithJobs","PrimaryPhone","OpenBalanceDate","Taxable","AlternatePhone","MetaData","ParentRef","Level","Notes","WebAddr","Active","Balance","ShipAddr","PaymentMethodRef","IsProject","CompanyName","GSTRegistrationType","PrintOnCheckName","BillAddr"],"Required":[],"RequiredForUpdate":["SyncToken"],"ConditionallyRequired":["DisplayName","Title","GivenName","MiddleName","Suffix","FamilyName"],"type":"object","properties":{"PrimaryEmailAddr":{"filterable":true,"$ref":[{"emailaddress":"EmailAddress"}],"type":"EmailAddress","requiredFlag":"Optional","description":"Primaryemailaddress."},"DisplayName":{"sortable":true,"description":"Thenameofthepersonororganizationasdisplayed.MustbeuniqueacrossallCustomer,Vendor,andEmployeeobjects.Cannotberemovedwithsparseupdate.\\nIfnotsupplied,thesystemgenerates<spanclass=\\"literal\\">DisplayName</span>byconcatenatingcustomernamecomponentssuppliedintherequestfromthefollowinglist:<spanclass=\\"literal\\">Title</span>,<spanclass=\\"literal\\">GivenName</span>,<spanclass=\\"literal\\">MiddleName</span>,<spanclass=\\"literal\\">FamilyName</span>,and<spanclass=\\"literal\\">Suffix</span>.","filterable":true,"requiredFlag":"Conditionallyrequired","maxLen":"maximumof500chars","type":"String"},"Title":{"maxLen":"maximumof16chars","type":"String","requiredFlag":"Conditionallyrequired","description":"Titleoftheperson.Thistagsupportsi18n,alllocales.The<spanclass=\\"literal\\">DisplayName</span>attributeoratleastoneof<spanclass=\\"literal\\">Title</span>,<spanclass=\\"literal\\">GivenName</span>,<spanclass=\\"literal\\">MiddleName</span>,<spanclass=\\"literal\\">FamilyName</span>,or<spanclass=\\"literal\\">Suffix</span>attributesisrequired."},"ResaleNum":{"maxLen":"16chars","type":"String","description":"Resalenumberorsomeadditionalinfoaboutthecustomer.","requiredFlag":"Optional"},"ARAccountRef":{"minorVersion":3,"description":"Identifiestheaccountsreceivableaccounttobeusedforthiscustomer.EachcustomermusthavehisownARaccount.ApplicableforFrancecompanies,only.Availablewhenendpointisevokedwiththe<spanclass=\\"literal\\">minorversion=3</span>queryparameter.\\nQuerytheAccountnamelistresourcetodeterminetheappropriateAccountobjectforthisreference,where<spanclass=\\"literal\\">Account.AccountType=AccountsReceivable</span>.Use<spanclass=\\"literal\\">Account.Id</span>and<spanclass=\\"literal\\">Account.Name</span>fromthatobjectfor<spanclass=\\"literal\\">ARAccountRef.value</span>and<spanclass=\\"literal\\">ARAccountRef.name</span>,respectively.","requiredFlag":"Optional","type":"ReferenceType","locales":["FR"],"$ref":[{"referencetype":"ReferenceType"}]},"DefaultTaxCodeRef":{"$ref":[{"referencetype":"ReferenceType"}],"type":"ReferenceType","requiredFlag":"Optional","description":"ReferencetoadefaulttaxcodeassociatedwiththisCustomerobject.Referenceisvalidif<spanclass=\\"literal\\">Customer.Taxable</span>issettotrue;otherwise,itisignored.\\nIfautomatedsalestaxisenabled(<spanclass=\\"literal\\">Preferences.TaxPrefs.PartnerTaxEnabled</span>issetto<spanclass=\\"literal\\">true</span>)thedefaulttaxcodeissetbythesystemandcannotbeoverridden.\\nQuerytheTaxCodenamelistresourcetodeterminetheappropriateTaxCodeobjectforthisreference.Use<spanclass=\\"literal\\">TaxCode.Id</span>and<spanclass=\\"literal\\">TaxCode.Name</span>fromthatobjectfor<spanclass=\\"literal\\">DefaultTaxCodeRef.value</span>and<spanclass=\\"literal\\">DefaultTaxCodeRef.name</span>,respectively."},"PreferredDeliveryMethod":{"type":"String","description":"Preferreddeliverymethod.ValuesarePrint,Email,orNone.","requiredFlag":"Optional"},"GSTIN":{"minorVersion":33,"requiredFlag":"Optional","maxLen":"maximumof15chars","type":"String","locales":["IN"],"description":"GSTINisanidentificationnumberassignedtoeveryGSTregisteredbusiness."},"GivenName":{"sortable":true,"description":"Givennameorfirstnameofaperson.The<spanclass=\\"literal\\">DisplayName</span>attributeoratleastoneof<spanclass=\\"literal\\">Title</span>,<spanclass=\\"literal\\">GivenName</span>,<spanclass=\\"literal\\">MiddleName</span>,<spanclass=\\"literal\\">FamilyName</span>,or<spanclass=\\"literal\\">Suffix</span>attributesisrequired.","filterable":true,"requiredFlag":"Conditionallyrequired","maxLen":"maximumof100chars","type":"String"},"SalesTermRef":{"$ref":[{"referencetype":"ReferenceType"}],"type":"ReferenceType","requiredFlag":"Optional","description":"ReferencetoaSalesTermassociatedwiththisCustomerobject.QuerytheTermnamelistresourcetodeterminetheappropriateTermobjectforthisreference.Use<spanclass=\\"literal\\">Term.Id</span>and<spanclass=\\"literal\\">Term.Name</span>fromthatobjectfor<spanclass=\\"literal\\">SalesTermRef.value</span>and<spanclass=\\"literal\\">SalesTermRef.name</span>,respectively."},"FullyQualifiedName":{"sortable":true,"description":"Fullyqualifiednameoftheobject.Thefullyqualifiednameprependsthetopmostparent,followedbyeachsubelementseparatedbycolons.Takestheformof\\n<spanclass=\\"literal\\">Customer:Job:Sub-job</span>.Systemgenerated.Limitedto5levels.","filterable":true,"requiredFlag":"Optional","systemDefined":true,"type":"String"},"Fax":{"maxLen":"maximumof30chars","$ref":[{"telephonenumber30":"TelephoneNumber30"}],"type":"TelephoneNumber","requiredFlag":"Optional","description":"Faxnumber."},"BusinessNumber":{"minorVersion":33,"requiredFlag":"Optional","maxLen":"maximumof10chars","type":"String","locales":["IN"],"description":"Alsocalled,PAN(inIndia)isacodethatactsasanidentificationforindividuals,familiesandcorporates,especiallyforthosewhopaytaxesontheirincome."},"BillWithParent":{"default":"false","type":"Boolean","description":"Iftrue,thisCustomerobjectisbilledwithitsparent.Iffalse,ornullthecustomerisnottobebilledwithitsparent.ThisattributeisvalidonlyifthisentityisaJoborsubCustomer.","requiredFlag":"Optional"},"CurrencyRef":{"description":"Referencetothecurrencyinwhichallamountsassociatedwiththiscustomerareexpressed.Onceset,itcannotbechanged.\\nIfspecifiedcurrencyisnotcurrentlyinthecompany\'scurrencylist,itisadded.\\nIfnotspecified,currencyforthiscustomeristhehomecurrencyofthecompany,asdefinedby<spanclass=\\"literal\\">Preferences.CurrencyPrefs.HomeCurrency</span>.[[\\n<strong>String</strong>\\nPreferreddeliverymethod.ValuesarePrint,Email,orNone.\\n<strong>String</strong>,16chars\\nResalenumberorsomeadditionalinfoaboutthecustomer.\\n<strong>ReferenceType</strong>\\nIdentifiestheaccountsreceivableaccounttobeusedforthiscustomer.EachcustomermusthavehisownARaccount.ApplicableforFrancecompanies,only.Availablewhenendpointisevokedwiththe<spanclass=\\"literal\\">minorversion=3</span>queryparameter.\\nQuerytheAccountnamelistresourcetodeterminetheappropriateAccountobjectforthisreference,where<spanclass=\\"literal\\">Account.AccountType=AccountsReceivable</span>.Use<spanclass=\\"literal\\">Account.Id</span>and<spanclass=\\"literal\\">Account.Name</span>fromthatobjectfor<spanclass=\\"literal\\">ARAccountRef.value</span>and<spanclass=\\"literal\\">ARAccountRef.name</span>,respectively.Read-onlyafterobjectiscreated","requiredFlag":"Optional","maxLen":"16chars","readOnly":true,"type":"CurrencyRef","$ref":[{"referencetype":"ReferenceType"}]},"Mobile":{"maxLen":"maximumof30chars","$ref":[{"telephonenumber30":"TelephoneNumber30"}],"type":"TelephoneNumber","requiredFlag":"Optional","description":"Mobilephonenumber."},"Job":{"default":"falseornull","type":"Boolean","description":"Iftrue,thisisaJoborsub-customer.Iffalseornull,thisisatoplevelcustomer,notaJoborsub-customer.","requiredFlag":"Optional"},"BalanceWithJobs":{"type":"Decimal","sortable":true,"requiredFlag":"Optional","description":"CumulativeopenbalanceamountfortheCustomer(orJob)andallitssub-jobs.CannotbewrittentoQuickBooks."},"PrimaryPhone":{"maxLen":"maximumof30chars","$ref":[{"telephonenumber30":"TelephoneNumber30"}],"type":"TelephoneNumber","requiredFlag":"Optional","description":"Primaryphonenumber."},"OpenBalanceDate":{"$ref":[{"date":"Date"}],"type":"Date","description":"DateoftheOpenBalanceforthecreateoperation.Write-on-create.","requiredFlag":"Optional"},"Taxable":{"type":"Boolean","description":"Iftrue,transactionsforthiscustomeraretaxable.\\nDefaultbehaviorwithminorversion10andabove:true,if<spanclass=\\"literal\\">DefaultTaxCodeRef</span>isdefinedorfalseif<spanclass=\\"literal\\">TaxExemptionReasonId</span>isset.","requiredFlag":"Optional"},"AlternatePhone":{"maxLen":"maximumof30chars","$ref":[{"telephonenumber30":"TelephoneNumber30"}],"type":"TelephoneNumber","requiredFlag":"Optional","description":"Alternatephonenumber."},"MetaData":{"$ref":[{"modificationmetadata":"ModificationMetadata"}],"type":"ModificationMetaData","requiredFlag":"Optional","description":"Descriptiveinformationabouttheentity.TheMetaDatavaluesaresetbyDataServicesandarereadonlyforallapplications."},"ParentRef":{"$ref":[{"referencetype":"ReferenceType"}],"type":"ReferenceType","requiredFlag":"Optional","description":"AreferencetoaCustomerobjectthatistheimmediateparentoftheSub-Customer/JobinthehierarchicalCustomer:Joblist.\\nRequiredforthecreateoperationifthisobjectisasub-customerorJob.QuerytheCustomernamelistresourcetodeterminetheappropriateCustomerobjectforthisreference.Use<spanclass=\\"literal\\">Customer.Id</span>and<spanclass=\\"literal\\">Customer.DisplayName</span>fromthatobjectfor<spanclass=\\"literal\\">ParentRef.value</span>and<spanclass=\\"literal\\">ParentRef.name</span>,respectively."},"Level":{"default":"0","type":"Integer","description":"Specifiesthelevelofthehierarchyinwhichtheentityislocated.Zerospecifiesthetoplevelofthehierarchy;anythingabovewillbelevelwithrespecttotheparent.\\n\\n<spanstyle=\\"color:#800080;\\">Constraints:</span>upto5levels","requiredFlag":"Optional"},"MiddleName":{"sortable":true,"description":"Middlenameoftheperson.Thepersoncanhavezeroormoremiddlenames.The<spanclass=\\"literal\\">DisplayName</span>attributeoratleastoneof<spanclass=\\"literal\\">Title</span>,<spanclass=\\"literal\\">GivenName</span>,<spanclass=\\"literal\\">MiddleName</span>,<spanclass=\\"literal\\">FamilyName</span>,or<spanclass=\\"literal\\">Suffix</span>attributesisrequired.","filterable":true,"requiredFlag":"Conditionallyrequired","maxLen":"maximumof100chars","type":"String"},"Notes":{"maxLen":"maximumof2000chars","type":"String","description":"FreeformtextdescribingtheCustomer.","requiredFlag":"Optional"},"TaxExemptionReasonId":{"type":"NumericId","minorVersion":10,"description":"Thetaxexemptionreasonassociatedwiththiscustomerobject.Applicableifautomatedsalestaxisenabled(<spanclass=\\"literal\\">Preferences.TaxPrefs.PartnerTaxEnabled</span>issetto<spanclass=\\"literal\\">true</span>)forthecompany.Set<spanclass=\\"literal\\">TaxExemptionReasonId:</span>tooneofthefollowing:\\n<table>\\n<thead>\\n<tr>\\n<th>Id</th>\\n<th>Reason</th>\\n</tr>\\n</thead>\\n<tbody>\\n<tr>\\n<td>1</td>\\n<td>Federalgovernment</td>\\n</tr>\\n<tr>\\n<td>2</td>\\n<td>Stategovernment</td>\\n</tr>\\n<tr>\\n<td>3</td>\\n<td>Localgovernment</td>\\n</tr>\\n<tr>\\n<td>4</td>\\n<td>Tribalgovernment</td>\\n</tr>\\n<tr>\\n<td>5</td>\\n<td>Charitableorganization</td>\\n</tr>\\n<tr>\\n<td>6</td>\\n<td>Religiousorganization</td>\\n</tr>\\n<tr>\\n<td>7</td>\\n<td>Educationalorganization</td>\\n</tr>\\n<tr>\\n<td>8</td>\\n<td>Hospital</td>\\n</tr>\\n<tr>\\n<td>9</td>\\n<td>Resale</td>\\n</tr>\\n<tr>\\n<td>10</td>\\n<td>Directpaypermit</td>\\n</tr>\\n<tr>\\n<td>11</td>\\n<td>Multiplepointsofuse</td>\\n</tr>\\n<tr>\\n<td>12</td>\\n<td>Directmail</td>\\n</tr>\\n<tr>\\n<td>13</td>\\n<td>Agriculturalproduction</td>\\n</tr>\\n<tr>\\n<td>14</td>\\n<td>Industrialproduction/manufacturing</td>\\n</tr>\\n<tr>\\n<td>15</td>\\n<td>Foreigndiplomat</td>\\n</tr>\\n</tbody>\\n</table>"},"WebAddr":{"maxLen":"maximumof1000chars","$ref":[{"websiteaddress":"WebsiteAddress"}],"type":"WebSiteAddress","requiredFlag":"Optional","description":"Websiteaddress."},"Active":{"sortable":true,"description":"Iftrue,thisentityiscurrentlyenabledforusebyQuickBooks.\\nIfthereisanamountin<spanclass=\\"literal\\">Customer.Balance</span>whensettingthisCustomerobjecttoinactivethroughtheQuickBooksUI,aCreditMemobalancingtransactioniscreatedfortheamount.","filterable":true,"requiredFlag":"Optional","default":"true","type":"Boolean"},"Balance":{"filterable":true,"type":"Decimal","sortable":true,"requiredFlag":"Optional","description":"Specifiestheopenbalanceamountortheamountunpaidbythecustomer.Forthecreateoperation,thisrepresentstheopeningbalanceforthecustomer.Whenreturnedinresponsetothequeryrequestitrepresentsthecurrentopenbalance(unpaidamount)forthatcustomer.Write-on-create."},"SyncToken":{"type":"String","requiredFlag":"Requiredforupdate","description":"Versionnumberoftheobject.Itisusedtolockanobjectforusebyoneappatatime.Assoonasanapplicationmodifiesanobject,its<spanclass=\\"literal\\">SyncToken</span>isincremented.Attemptstomodifyanobjectspecifyinganolder<spanclass=\\"literal\\">SyncToken</span>fails.OnlythelatestversionoftheobjectismaintainedbyQuickBooksOnline."},"ShipAddr":{"table":{"physical_address":["Showmoredetails","Hidedetails"]},"$ref":[{"physicaladdress":"PhysicalAddress"}],"type":"PhysicalAddress","requiredFlag":"Optional","description":"Defaultshippingaddress.Ifaphysicaladdressisupdatedfromwithinthetransactionobject,theQuickBooksOnlineAPIflowsindividualaddresscomponentsdifferentlyintotheLineelementsofthetransactionresponsethenwhenthetransactionwasfirstcreated:</p><ul><li><spanclass=\\"literal\\">Line1</span>and<spanclass=\\"literal\\">Line2</span>elementsarepopulatedwiththecustomernameandcompanyname.</li><li>Original<spanclass=\\"literal\\">Line1</span>through<spanclass=\\"literal\\">Line5</span>contents,<spanclass=\\"literal\\">City</span>,<spanclass=\\"literal\\">SubDivisionCode</span>,and<spanclass=\\"literal\\">PostalCode</span>flowinto<spanclass=\\"literal\\">Line3</span>through<spanclass=\\"literal\\">Line5</span>asafreeformatstrings.</li></ul>"},"PaymentMethodRef":{"$ref":[{"referencetype":"ReferenceType"}],"type":"ReferenceType","requiredFlag":"Optional","description":"ReferencetoaPaymentMethodassociatedwiththisCustomerobject.QuerythePaymentMethodnamelistresourcetodeterminetheappropriatePaymentMethodobjectforthisreference.Use<spanclass=\\"literal\\">PaymentMethod.Id</span>and<spanclass=\\"literal\\">PaymentMethod.Name</span>fromthatobjectfor<spanclass=\\"literal\\">PaymentMethodRef.value</span>and<spanclass=\\"literal\\">PaymentMethodRef.name</span>,respectively."},"Suffix":{"sortable":false,"description":"Suffixofthename.Forexample,<spanclass=\\"literal\\">Jr</span>.The<spanclass=\\"literal\\">DisplayName</span>attributeoratleastoneof<spanclass=\\"literal\\">Title</span>,<spanclass=\\"literal\\">GivenName</span>,<spanclass=\\"literal\\">MiddleName</span>,<spanclass=\\"literal\\">FamilyName</span>,or<spanclass=\\"literal\\">Suffix</span>attributesisrequired.","filterable":false,"requiredFlag":"Conditionallyrequired","maxLen":"maximumof16chars","type":"String"},"IsProject":{"default":"Falseornull","description":"Iftrue,indicatesthisisaProject.","type":"Boolean","requiredFlag":"Optional","minorVersion":25},"CompanyName":{"sortable":true,"description":"Thenameofthecompanyassociatedwiththepersonororganization.","filterable":true,"requiredFlag":"Optional","maxLen":"maximumof100chars","type":"String"},"FamilyName":{"sortable":true,"description":"Familynameorthelastnameoftheperson.The<spanclass=\\"literal\\">DisplayName</span>attributeoratleastoneof<spanclass=\\"literal\\">Title</span>,<spanclass=\\"literal\\">GivenName</span>,<spanclass=\\"literal\\">MiddleName</span>,<spanclass=\\"literal\\">FamilyName</span>,or<spanclass=\\"literal\\">Suffix</span>attributesisrequired.","filterable":true,"requiredFlag":"Conditionallyrequired","maxLen":"maximumof100chars","type":"String"},"GSTRegistrationType":{"minorVersion":33,"requiredFlag":"Optional","maxLen":"maximumof15chars","type":"String","locales":["IN"],"description":"ForthefilingofGSTR,transactionsneedtobeclassifieddependingonthetypeofcustomertowhomthesaleisdone.Tofacilitatethis,wehaveintroducedanewfieldas\'GSTregistrationtype\'.Possiblevaluesarelistedbelow:\\n<li><spanclass=\\"literal\\">GST_REG_REG</span>GSTregistered-Regular.CustomerwhohasabusinesswhichisregisteredunderGSTandhasaGSTIN(doesn\\u2019tincludecustomersregisteredundercompositionscheme,asanSEZorasEOU\'s,STP\'sEHTP\'setc.).</li>\\n<li><spanclass=\\"literal\\">GST_REG_COMP</span>GSTregistered-Composition.CustomerwhohasabusinesswhichisregisteredunderthecompositionschemeofGSTandhasaGSTIN.</li>\\n<li><spanclass=\\"literal\\">GST_UNREG</span>GSTunregistered.CustomerwhohasabusinesswhichisnotregisteredunderGSTanddoesnothaveaGSTIN.</li>\\n<li><spanclass=\\"literal\\">CONSUMER</span>Consumer.CustomerwhoisnotregisteredunderGSTandisthefinalconsumeroftheserviceorproductsold.</li>\\n<li><spanclass=\\"literal\\">OVERSEAS</span>Overseas.CustomerwhohasabusinesswhichislocatedoutofIndia.</li>\\n<li><spanclass=\\"literal\\">SEZ</span>SEZ.CustomerwhohasabusinesswhichisregisteredunderGST,hasaGSTINandislocatedinaSEZorisaSEZDeveloper.</li>\\n<li><spanclass=\\"literal\\">DEEMED</span>Deemedexports-EOU\'s,STP\'sEHTP\'setc.CustomerwhohasabusinesswhichisregisteredunderGSTandfallsinthecategoryofcompanies(EOU\'s,STP\'sEHTP\'setc.),towhichsuppliesaremadetheyaretermedasdeemedexports.</li>"},"PrintOnCheckName":{"sortable":true,"description":"Nameofthepersonororganizationasprintedonacheck.Ifnotprovided,thisispopulatedfromDisplayName.\\n\\n<spanstyle=\\"color:#800080;\\">Constraints:</span>Cannotberemovedwithsparseupdate.","filterable":true,"requiredFlag":"Optional","maxLen":"maximumof110chars","type":"String"},"BillAddr":{"table":{"physical_address":["Showmoredetails","Hidedetails"]},"$ref":[{"physicaladdress":"PhysicalAddress"}],"type":"PhysicalAddress","requiredFlag":"Optional","description":"Defaultbillingaddress.Ifaphysicaladdressisupdatedfromwithinthetransactionobject,theQuickBooksOnlineAPIflowsindividualaddresscomponentsdifferentlyintotheLineelementsofthetransactionresponsethenwhenthetransactionwasfirstcreated:</p><ul><li><spanclass=\\"literal\\">Line1</span>and<spanclass=\\"literal\\">Line2</span>elementsarepopulatedwiththecustomernameandcompanyname.</li><li>Original<spanclass=\\"literal\\">Line1</span>through<spanclass=\\"literal\\">Line5</span>contents,<spanclass=\\"literal\\">City</span>,<spanclass=\\"literal\\">SubDivisionCode</span>,and<spanclass=\\"literal\\">PostalCode</span>flowinto<spanclass=\\"literal\\">Line3</span>through<spanclass=\\"literal\\">Line5</span>asafreeformatstrings.</li></ul>"},"Id":{"filterable":true,"sortable":true,"type":"String","description":"Uniqueidentifierforthisobject.\\nSortorderisASCbydefault.","requiredFlag":"Requiredforupdate"}}}}}}';
}