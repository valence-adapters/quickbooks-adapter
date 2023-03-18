/**
 * Connects Valence and Quickbooks
 */
global with sharing class QuickbooksAdapter implements valence.SchemaAwareTransformationFilter {

	public Boolean validFor(valence.LinkContext context) {
		return true;
	}

	public void process(valence.LinkContext context, List<valence.RecordInFlight> records) {

	}

  public valence.FilterSchema describeSchema(valence.LinkContext context) {
    return null;
  }
}
