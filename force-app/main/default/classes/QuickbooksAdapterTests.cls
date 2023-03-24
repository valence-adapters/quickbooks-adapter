/**
 * Exercises the QuickbooksAdapter class.
 */
@IsTest
private class QuickbooksAdapterTests implements HttpCalloutMock {

	@IsTest
	static void testTables() {
		List<valence.Table> tables = new QuickbooksAdapter().getTables();
		System.assertEquals(2, tables.size());
		System.assertEquals('Customer', tables[0].name);
		System.assertEquals('Customer', tables[0].label);
	}

	@IsTest
	static void testFields() {
		List<valence.Field> fields = new QuickbooksAdapter().getFields('Customer');
		System.assertEquals(42, fields.size());
	}

	@IsTest
	static void testLimit() {
		System.assertEquals(30, new QuickbooksAdapter().getBatchSizeLimit(null));
	}

	@IsTest
	static void testQueryBuilding() {

		Datetime timestamp = Datetime.newInstance(2020, 2, 11, 3, 17, 45);
		System.assertEquals('SELECT COUNT(*) FROM Customer WHERE Metadata.LastUpdatedTime >= \'2020-02-11T03:17:45-10:00\' startposition 1 maxresults 1000', QuickbooksAdapter.buildQuery('Customer', 1, 1000, timestamp, null, true));
		System.assertEquals('SELECT * FROM Invoice WHERE Metadata.LastUpdatedTime >= \'2020-02-11T03:17:45-10:00\' startposition 4 maxresults 1000', QuickbooksAdapter.buildQuery('Invoice', 4, 1000, timestamp, null, false));
		System.assertEquals('SELECT COUNT(*) FROM Customer startposition 1 maxresults 300', QuickbooksAdapter.buildQuery('Customer', 1, 300, null, null, true));
		System.assertEquals('SELECT * FROM Invoice startposition 7 maxresults 77', QuickbooksAdapter.buildQuery('Invoice', 7, 77, null, null, false));
		System.assertEquals('SELECT Id,SyncToken FROM Vendor WHERE Id IN (\'11\') startposition 1 maxresults 1000', QuickbooksAdapter.buildQuery('Vendor', 1, 1000, null, new List<String>{'11'}, false));
		System.assertEquals('SELECT Id,SyncToken FROM Customer WHERE Id IN (\'11\',\'14\') startposition 16 maxresults 4', QuickbooksAdapter.buildQuery('Customer', 16, 4, null, new List<String>{'11', '14'}, false));
	}

	@IsTest
	static void testPlanFetchNoRecords() {

		Test.setMock(HttpCalloutMock.class, new QuickbooksAdapterTests());

		valence.LinkContext context = new valence.LinkContext();
		context.linkSourceName = 'Customer';
		context.batchSizeLimit = 20;

		QuickbooksAdapter adapter = new QuickbooksAdapter();
		adapter.setNamedCredential('planFetchNoRecords');
		adapter.setSourceConfiguration(context, '{"realmId":"123"}');

		valence.FetchStrategy strategy = adapter.planFetch(context);
		System.assertEquals('NO_RECORDS', strategy.checkStrategyType());
	}

	@IsTest
	static void testPlanFetchImmediate() {

		Test.setMock(HttpCalloutMock.class, new QuickbooksAdapterTests());

		valence.LinkContext context = new valence.LinkContext();
		context.linkSourceName = 'Customer';
		context.batchSizeLimit = 20;

		QuickbooksAdapter adapter = new QuickbooksAdapter();
		adapter.setNamedCredential('planFetchImmediate');
		adapter.setSourceConfiguration(context, '{"realmId":"123"}');

		valence.FetchStrategy strategy = adapter.planFetch(context);
		System.assertEquals(12, strategy.checkExpectedTotalRecords());
		System.assertEquals('IMMEDIATE', strategy.checkStrategyType());
	}

	@IsTest
	static void testPlanFetchScopes() {

		Test.setMock(HttpCalloutMock.class, new QuickbooksAdapterTests());

		valence.LinkContext context = new valence.LinkContext();
		context.linkSourceName = 'Customer';
		context.batchSizeLimit = 10;

		QuickbooksAdapter adapter = new QuickbooksAdapter();
		adapter.setNamedCredential('planFetchScopes');
		adapter.setSourceConfiguration(context, '{"realmId":"123"}');

		valence.FetchStrategy strategy = adapter.planFetch(context);
		System.assertEquals(12, strategy.checkExpectedTotalRecords());
		System.assertEquals(2, strategy.checkScopeCount());
		System.assertEquals('SCOPES', strategy.checkStrategyType());
	}

	@IsTest
	static void testFetchCustomers() {

		Test.setMock(HttpCalloutMock.class, new QuickbooksAdapterTests());

		valence.LinkContext context = new valence.LinkContext();
		context.linkSourceName = 'Customer';

		QuickbooksAdapter adapter = new QuickbooksAdapter();
		adapter.setNamedCredential('fetchCustomers');
		adapter.setSourceConfiguration(context, '{"realmId":"123"}');
		List<valence.RecordInFlight> records = adapter.fetchRecords(context, null);

		System.assertEquals(2, records.size());
		System.assertEquals('Acme', records[0].getOriginalPropertyValue('CompanyName'));
	}

	@IsTest
	static void testPushCustomers() {

		Test.setMock(HttpCalloutMock.class, new QuickbooksAdapterTests());

		valence.LinkContext context = new valence.LinkContext();
		context.linkSourceName = 'Account';
		context.linkTargetName = 'Customer';

		QuickbooksAdapter adapter = new QuickbooksAdapter();
		adapter.setNamedCredential('pushCustomers');
		adapter.setTargetConfiguration(context, '{"realmId":"123"}');

		List<valence.RecordInFlight> records = new List<valence.RecordInFlight>{
			new valence.RecordInFlight(new Map<String, Object>()),
			new valence.RecordInFlight(new Map<String, Object>())
		};

		records[0].setPropertyValue('Id', '27');
		records[0].setPropertyValue('DisplayName', 'Acme');

		records[1].setPropertyValue('DisplayName', 'Binko');

		adapter.pushRecords(context, records);
	}

	public HttpResponse respond(HttpRequest req) {

		HttpResponse res = new HttpResponse();
		res.setStatusCode(200);
		res.setStatus('OK');

		if(req.getEndpoint().startsWith('callout:planFetchNoRecords')) {
			res.setBody(
				'{\n' +
					'    "QueryResponse": {\n' +
					'        "totalCount": 0\n' +
					'    },\n' +
					'    "time": "2021-01-23T00:41:26.597-08:00"\n' +
					'}'
			);
		}
		else if(req.getEndpoint().startsWith('callout:planFetchImmediate')) {
			res.setBody(
				'{\n' +
					'    "QueryResponse": {\n' +
					'        "totalCount": 12\n' +
					'    },\n' +
					'    "time": "2021-01-23T00:41:26.597-08:00"\n' +
					'}'
			);
		}
		else if(req.getEndpoint().startsWith('callout:planFetchScopes')) {
			res.setBody(
				'{\n' +
					'    "QueryResponse": {\n' +
					'        "totalCount": 12\n' +
					'    },\n' +
					'    "time": "2021-01-23T00:41:26.597-08:00"\n' +
					'}'
			);
		}
		else if(req.getEndpoint().startsWith('callout:fetchCustomers')) {
			res.setBody(
				'{' +
					'  "time" : "2021-01-22T22:58:49.891-08:00",' +
					'  "QueryResponse" : {' +
					'    "maxResults" : 12,' +
					'    "startPosition" : 1,' +
					'    "Customer" : [ {' +
					'      "PrimaryEmailAddr" : {' +
					'        "Address" : "tom@example.com"' +
					'      },' +
					'      "PrimaryPhone" : {' +
					'        "FreeFormNumber" : "(555) 555-1642"' +
					'      },' +
					'      "Active" : true,' +
					'      "PrintOnCheckName" : "Acme",' +
					'      "DisplayName" : "Acme",' +
					'      "CompanyName" : "Acme",' +
					'      "FullyQualifiedName" : "Acme",' +
					'      "MetaData" : {' +
					'        "LastUpdatedTime" : "2020-07-29T18:13:10-07:00",' +
					'        "CreateTime" : "2019-10-21T23:28:48-07:00"' +
					'      },' +
					'      "SyncToken" : "2",' +
					'      "Id" : "10",' +
					'      "sparse" : false,' +
					'      "domain" : "QBO",' +
					'      "PreferredDeliveryMethod" : "None",' +
					'      "CurrencyRef" : {' +
					'        "name" : "United States Dollar",' +
					'        "value" : "USD"' +
					'      },' +
					'      "BalanceWithJobs" : 25000.02,' +
					'      "Balance" : 25000.02,' +
					'      "BillWithParent" : false,' +
					'      "Job" : false,' +
					'      "ShipAddr" : {' +
					'        "PostalCode" : "30005",' +
					'        "CountrySubDivisionCode" : "GA",' +
					'        "Country" : "United States",' +
					'        "City" : "Alpharetta",' +
					'        "Line1" : "123 Main St",' +
					'        "Id" : "14"' +
					'      },' +
					'      "BillAddr" : {' +
					'        "PostalCode" : "30005",' +
					'        "CountrySubDivisionCode" : "GA",' +
					'        "Country" : "United States",' +
					'        "City" : "Alpharetta",' +
					'        "Line1" : "123 Main St",' +
					'        "Id" : "14"' +
					'      },' +
					'      "Taxable" : false' +
					'    }, {' +
					'      "PrimaryEmailAddr" : {' +
					'        "Address" : "sarah@example.org"' +
					'      },' +
					'      "Active" : true,' +
					'      "PrintOnCheckName" : "Sample Co",' +
					'      "DisplayName" : "Sample Co",' +
					'      "CompanyName" : "Sample Co",' +
					'      "FullyQualifiedName" : "Sample Co",' +
					'      "MetaData" : {' +
					'        "LastUpdatedTime" : "2021-01-22T20:28:06-08:00",' +
					'        "CreateTime" : "2019-10-22T13:25:28-07:00"' +
					'      },' +
					'      "SyncToken" : "1",' +
					'      "Id" : "11",' +
					'      "sparse" : false,' +
					'      "domain" : "QBO",' +
					'      "PreferredDeliveryMethod" : "None",' +
					'      "CurrencyRef" : {' +
					'        "name" : "United States Dollar",' +
					'        "value" : "USD"' +
					'      },' +
					'      "BalanceWithJobs" : 0,' +
					'      "Balance" : 0,' +
					'      "BillWithParent" : false,' +
					'      "Job" : false,' +
					'      "Notes" : "Test notes",' +
					'      "Taxable" : false' +
					'    } ]' +
					'  }' +
					'}'
			);
		}
		else if(req.getEndpoint().startsWith('callout:pushCustomers')) {
			System.debug(LoggingLevel.WARN, 'Eval: ' + req.getBody());
			if(req.getEndpoint().contains('query')) { // syncToken fetch
				System.debug(LoggingLevel.WARN, 'SyncTokenFetch');
				res.setBody(
					'{\n' +
						'    "QueryResponse": {\n' +
						'        "Customer": [\n' +
						'            {\n' +
						'                "sparse": true,\n' +
						'                "Id": "27",\n' +
						'                "SyncToken": "1"\n' +
						'            }\n' +
						'        ],\n' +
						'        "startPosition": 1,\n' +
						'        "maxResults": 3\n' +
						'    },\n' +
						'    "time": "2021-01-23T01:09:26.402-08:00"\n' +
						'}'
				);
			}
			else { // pushrecords write
				System.debug(LoggingLevel.WARN, 'ActualPush');
				res.setBody(
					'{\n' +
						'  "BatchItemResponse": [\n' +
						'    {\n' +
						'      "Customer": {\n' +
						'        "Taxable": false,\n' +
						'        "Notes": "Test notes",\n' +
						'        "Job": false,\n' +
						'        "BillWithParent": false,\n' +
						'        "Balance": 0,\n' +
						'        "BalanceWithJobs": 0,\n' +
						'        "CurrencyRef": {\n' +
						'          "value": "USD",\n' +
						'          "name": "United States Dollar"\n' +
						'        },\n' +
						'        "PreferredDeliveryMethod": "None",\n' +
						'        "domain": "QBO",\n' +
						'        "sparse": false,\n' +
						'        "Id": "27",\n' +
						'        "SyncToken": "2",\n' +
						'        "MetaData": {\n' +
						'          "CreateTime": "2019-10-22T13:25:29-07:00",\n' +
						'          "LastUpdatedTime": "2021-01-22T20:28:06-08:00"\n' +
						'        },\n' +
						'        "FullyQualifiedName": "Acme",\n' +
						'        "CompanyName": "Acme",\n' +
						'        "DisplayName": "Acme",\n' +
						'        "PrintOnCheckName": "Acme",\n' +
						'        "Active": true,\n' +
						'        "PrimaryEmailAddr": {\n' +
						'          "Address": "test@acme.com"\n' +
						'        }\n' +
						'      },\n' +
						'      "bId": "0014p00001g5fIUAAX"\n' +
						'    },\n' +
						'    {\n' +
						'      "Customer": {\n' +
						'        "Taxable": false,\n' +
						'        "Notes": "",\n' +
						'        "Job": false,\n' +
						'        "BillWithParent": false,\n' +
						'        "Balance": 0,\n' +
						'        "BalanceWithJobs": 0,\n' +
						'        "CurrencyRef": {\n' +
						'          "value": "USD",\n' +
						'          "name": "United States Dollar"\n' +
						'        },\n' +
						'        "PreferredDeliveryMethod": "None",\n' +
						'        "domain": "QBO",\n' +
						'        "sparse": false,\n' +
						'        "Id": "11",\n' +
						'        "SyncToken": "1",\n' +
						'        "MetaData": {\n' +
						'          "CreateTime": "2019-10-22T13:25:29-07:00",\n' +
						'          "LastUpdatedTime": "2021-01-22T20:28:06-08:00"\n' +
						'        },\n' +
						'        "FullyQualifiedName": "Binko",\n' +
						'        "CompanyName": "Binko",\n' +
						'        "DisplayName": "Binko",\n' +
						'        "PrintOnCheckName": "Binko",\n' +
						'        "Active": true,\n' +
						'        "PrimaryEmailAddr": {\n' +
						'          "Address": "test@binko.com"\n' +
						'        }\n' +
						'      },\n' +
						'      "bId": "0014p00001g5fIUAAY"\n' +
						'    }\n' +
						'  ],\n' +
						'  "time": "2021-01-23T01:11:02.031-08:00"\n' +
						'}'
				);
			}
		}

		return res;
	}
}