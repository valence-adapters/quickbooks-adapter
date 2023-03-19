# Quickbooks Adapter

This is a custom extension for <a href="https://valence.app">Valence</a>, a <a href="https://appexchange.salesforce.com/appxListingDetail?listingId=a0N3A00000EORP4UAP">managed package on the Salesforce AppExchange</a> that provides integration middleware natively in a Salesforce org.

To learn more about developing extensions for the Valence platform, have a look at <a href="https://docs.valence.app">the Valence documentation</a>.

## Installing

This Adapter uses a Valence base LWC called <a href="https://github.com/valence-filters/valence-ui-configurator">Valence UI Configurator</a>. If you don't already have it in your org, you can install it with this first button:

<a href="https://githubsfdeploy.herokuapp.com?owner=valence-filters&repo=ui-configurator-installer&ref=main">
  <img alt="Deploy to Salesforce"
       src="https://raw.githubusercontent.com/afawcett/githubsfdeploy/master/deploy.png">
</a>

Click this button to install the Quickbooks Adapter into your org.

<a href="https://githubsfdeploy.herokuapp.com?owner=valence-filters&repo=quickbooks-adapter&ref=main">
  <img alt="Deploy to Salesforce"
       src="https://raw.githubusercontent.com/afawcett/githubsfdeploy/master/deploy.png">
</a>

## What Does This Adapter Do?

Connects Valence and Quickbooks Online, an accounting and bookkeeping platform. You can write records bidirectionally, including nested/compound records such as Invoices + Invoice Line Items.

### Setting Up Authentication

In the Adapter package are an Auth Provider record with a pre-registered Valence app for Quickbooks, and a Named Credential that uses it. To link to your own Quickbooks org navigate to the Named Credential in the Setup menu in Salesforce, and start the authentication flow to set up the handshake with Quickbooks.

![Starting the authentication flow](/images/start_authentication_flow.png)

In addition to the Named Credential you will need the "realm id" (also called the "company id"), a unique value that represents your Quickbooks organization. Put this key in the configuration fields (repeated twice) on the Quickbooks Online Adapter Custom Metadata Record (go to Valence Adapters -> Manage Records in the Custom Metadata Types section of the Salesforce Setup menu).

![Adding your QBO Realm Id](/images/adding_the_realm_id.png)

### Configuring the Adapter for Writebacks

An important part of synchronizing with Quickbooks is saving Quickbook IDs back into Salesforce, so you can update records once they exist in QBO.

There is a custom LWC that handles this configuration. It's a little confusing at first, but understand that you can take any field you get back from Quickbooks, and write it to the Salesforce record (or records) that were the original records.

The reason you can write back to multiple records is that sometimes you are pulling compound records from Salesforce. For example, if you take an Invoice and its Line Items and write to Quickbooks, you want to write identifiers back to Salesforce not just for the Invoice but for each of its child Line Items as well.

![Here's what configuring the Adapter for writebacks looks like](/images/adapter_writeback_configuration.png)
