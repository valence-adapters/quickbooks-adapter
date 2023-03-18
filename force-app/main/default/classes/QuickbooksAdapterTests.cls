/**
 * Exercises the QuickbooksAdapter class.
 */
@IsTest
private class QuickbooksAdapterTests {

	@IsTest static void testRestrictions() {

		System.assertEquals(true, new QuickbooksAdapter().validFor(null));
	}

}
