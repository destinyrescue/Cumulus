/*
    Copyright (c) 2018, Salesforce.org
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of Salesforce.org nor the names of
      its contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
    "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
    LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
    FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
    COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
    INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
    BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
    LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
    CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
    LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
    ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
    POSSIBILITY OF SUCH DAMAGE.
*/
/**
* @author Salesforce.org
* @date 2018
* @group Rollups
* @group-content ../../ApexDocContent/Rollups2.htm
* @description Abstract base class for all Customizable Rollup batch jobs
*/
public abstract class CRLP_Batch_Base {

    /** @description The job type for this batch job -- AccountHardCredit, AccountSoftCredit, etc. */
    protected CRLP_RollupProcessingOptions.RollupType jobType;

    /** @description The default batch job mode - SkewMode (i.e., where the main batch job query is on the Detail object)
    * or NonSkew (where the main batch job query is on the Summary object) */
    protected CRLP_RollupProcessingOptions.BatchJobMode jobMode = CRLP_RollupProcessingOptions.BatchJobMode.NonSkewMode;

    /** @description The default filter to apply to Rollups type records for the processing */
    protected CRLP_RollupProcessingOptions.RollupTypeFilter jobFilter = CRLP_RollupProcessingOptions.RollupTypeFilter.All;

    /** @description This is built one time at the start of the batch process and then re-used throughout
     * the rest of the batch processing logic. This data is passed in the
     * ProcessingOptions collection to the processor. It's also used to pre-generate the SOQL used to retrieve
     * summary or detail records rather than build that in every single batch iteration. Basically this collection
     * is injected into the CRLP_Rollup_SEL cache to significantly simplify and narrow the number of records
     * retrieved and cached throughout the job.
     */
    protected List<Rollup__mdt> statefulCacheOfRollupsToBeProcessed = new List<Rollup__mdt>();

    /**
     * @description Map of Opportunity Id's already processed by Account to avoid duplicating a donation amount
     * to the Account when rolling up soft credits by the Contact.AccountId
     */
    protected Map<Id,Set<Id>> statefulMapOfOppIdsByParentId;

    /** @description Simple counters used to track state */
    protected Integer batchIteration = 0;

    /** @description Simple counters used to track state */
    protected Integer totalRecordsModified = 0;

    /** @description Simple counters used to track state */
    protected Integer totalCommits=0;

    /** @description Specified list of Summary (Account, Contact or GAU) Id's to roll up */
    protected List<Id> recordIds;

    /** @description The Summary Object Type this batch job will process */
    protected SObjectType summaryObjectType;

    /** @description The Detail Object Type this batch job will process */
    protected SObjectType detailObjectType;

    /** @description The Detail Object field that will be used in the inner join */
    protected String keyField;

    /** @description Whether this class was constructed from within a scheduled job */
    @TestVisible
    protected Boolean isScheduledJob {
        get {
            return isScheduledJob;
        }
        private set;
    }

    /*******************************************************************************************************
     * @description Constructs the class, inits the class instance vars used across all CRLP batch jobs
     */
    public CRLP_Batch_Base() {
        this.statefulMapOfOppIdsByParentId = new Map<Id, Set<Id>>();
        this.summaryObjectType = CRLP_RollupBatch_SVC.getSummaryObjectType(this.jobType);
        this.isScheduledJob = System.isScheduled();
    }

    /*******************************************************************************************************
     * @description Constructs the class - rollup is for a specific Summary SObject
     */
    public CRLP_Batch_Base(CRLP_RollupProcessingOptions.RollupType jobType, CRLP_RollupProcessingOptions.RollupTypeFilter jobFilter) {
        this();
        this.jobType = jobType;
        this.jobFilter = jobFilter;
    }

    /*******************************************************************************************************
     * @description Constructs the class - Rollup is for a specific set of Summary Object Id's
     */
    public CRLP_Batch_Base(CRLP_RollupProcessingOptions.RollupType jobType, List<Id> recordIds) {
        this();
        this.jobType = jobType;
        this.recordIds = recordIds;
    }

    /********************************************************************************************************
     * @description Create an instance of the CRLP_RollupProcessingOptions.ProcessingOptions class to use with the
     * CRLP_RollupProcessor_SVC.startRollupProcess() calls.
     * @return CRLP_RollupProcessingOptions.ProcessingOptions
     */
    protected CRLP_RollupProcessingOptions.ProcessingOptions initOptionsInstance() {
        CRLP_RollupProcessingOptions.ProcessingOptions options = new CRLP_RollupProcessingOptions.ProcessingOptions();
        options.detailObjType = Opportunity.SObjectType;    // the default type
        options.parentObjType = this.summaryObjectType;

        options.rollupJobType = this.jobType;
        options.rollupTypesToProcess = this.jobFilter;
        options.mode = this.jobMode;

        if (this.jobType == CRLP_RollupProcessingOptions.RollupType.AccountHardCredit) {
            options.parentKeyField = SObjectType.Opportunity.fields.AccountId.getName();

        } else if (this.jobType == CRLP_RollupProcessingOptions.RollupType.AccountSoftCredit) {
            options.parentKeyField = SObjectType.Account_Soft_Credit__c.fields.Account__c.getName();
            options.detailObjType = Account_Soft_Credit__c.SObjectType;

        } else if (this.jobType == CRLP_RollupProcessingOptions.RollupType.ContactHardCredit) {
            options.parentKeyField = SObjectType.Opportunity.fields.Primary_Contact__c.getName();

        } else if (this.jobType == CRLP_RollupProcessingOptions.RollupType.ContactSoftCredit) {
            options.parentKeyField = SObjectType.Partial_Soft_Credit__c.fields.Contact__c.getName();
            options.detailObjType = Partial_Soft_Credit__c.SObjectType;

        } else if (this.jobType == CRLP_RollupProcessingOptions.RollupType.AccountContactSoftCredit) {
            options.parentKeyField = SObjectType.Partial_Soft_Credit__c.fields.Contact__c.getName().replace('__c','__r') + '.AccountId';
            options.detailObjType = Partial_Soft_Credit__c.SObjectType;

        } else if (this.jobType == CRLP_RollupProcessingOptions.RollupType.GAU) {
            options.parentKeyField = SObjectType.Allocation__c.fields.General_Accounting_Unit__c.getName();
            options.detailObjType = Allocation__c.SObjectType;

        } else if (this.jobType == CRLP_RollupProcessingOptions.RollupType.RecurringDonations) {
            options.parentKeyField = SObjectType.Opportunity.fields.npe03__Recurring_Donation__c.getName();

        }

        // Retrieve and store the cached list of Rollup__mdt records into the Rollups Processor
        // so that the list never changes throughout the life of the batch job
        if (this.statefulCacheOfRollupsToBeProcessed != null) {
            CRLP_Rollup_SEL.stuffRollupsByTypeCache(this.jobType, this.jobFilter,
                    this.statefulCacheOfRollupsToBeProcessed);
        }

        return options;
    }

    /**
     * @description For a given set of records, returns a Set<Id> of parent records using the passed field name as the parent
     * @param detailRecords List<SObject>
     * @param parentKeyField API Name of the parent field to use for the Id
     * @return List<Id>
     */
    protected List<Id> getParentIdsFromDetailRecords(List<SObject> detailRecords, String parentKeyField) {
        Set<Id> parentIdSet = new Set<Id>();
        List<Id> parentIds = new List<Id>();
        // If the parentKeyField is something like Contact.AccountId, then have to retrieve the parent SObject
        // first and then get the field value.
        String parentObjectField;
        if (parentKeyField.contains('.')) {
            parentObjectField = parentKeyField.split('\\.')[0];
            parentKeyField = parentKeyField.split('\\.')[1];
        }
        for (SObject dtl : detailRecords) {
            SObject dtlRecord = dtl;
            if (parentObjectField != null) {
                dtlRecord = dtl.getSObject(parentObjectField);
            }
            if (dtlRecord.get(parentKeyField) != null) {
                Id parentId = (Id)dtlRecord.get(parentKeyField);
                // Use a set to ensure that the parentId is only in the collection one time since there is no
                // contains() yet, but use a List to keep the parentId records in the exact same sequence
                // that they are in the details collection
                if (!parentIdSet.contains(parentId)) {
                    parentIds.add(parentId);
                    parentIdSet.add(parentId);
                }
            }
        }
        return parentIds;
    }

    /**
     * @description Called during the start() method for the actual batch job to initialize the summary object, detail
     * object, key field, and if there are payment rollups that need to be included for the given summary object
     */
    @TestVisible protected void initializeJobData() {
        this.summaryObjectType = CRLP_RollupBatch_SVC.getSummaryObjectType(this.jobType);
        this.statefulCacheOfRollupsToBeProcessed = CRLP_Rollup_SEL.getRollupDefinitionsToUse(this.jobType, this.jobFilter);

        if (this.jobType == CRLP_RollupProcessingOptions.RollupType.GAU) {
            this.detailObjectType = Allocation__c.SObjectType;
            this.keyField = SObjectType.Allocation__c.fields.General_Accounting_Unit__c.getName();

        } else if (this.jobType == CRLP_RollupProcessingOptions.RollupType.AccountHardCredit) {
            this.detailObjectType = Opportunity.SObjectType;
            this.keyField = SObjectType.Opportunity.fields.AccountId.getName();

        } else if (this.jobType == CRLP_RollupProcessingOptions.RollupType.AccountSoftCredit) {
            this.detailObjectType = Account_Soft_Credit__c.SObjectType;
            this.keyField = SObjectType.Account_Soft_Credit__c.fields.Account__c.getName();

        } else if (this.jobType == CRLP_RollupProcessingOptions.RollupType.ContactHardCredit) {
            this.detailObjectType = Opportunity.SObjectType;
            this.keyField = SObjectType.Opportunity.fields.Primary_Contact__c.getName();

        } else if (this.jobType == CRLP_RollupProcessingOptions.RollupType.ContactSoftCredit) {
            this.detailObjectType = OpportunityContactRole.SObjectType;
            this.keyField = SObjectType.OpportunityContactRole.fields.ContactId.getName();

        } else if (this.jobType == CRLP_RollupProcessingOptions.RollupType.AccountContactSoftCredit) {
            this.detailObjectType = OpportunityContactRole.SObjectType;
            this.keyField = 'Contact.AccountId';

        } else if (this.jobType == CRLP_RollupProcessingOptions.RollupType.RecurringDonations) {
            this.detailObjectType = Opportunity.SObjectType;
            this.keyField = SObjectType.Opportunity.fields.npe03__Recurring_Donation__c.getName();
        }
    }

    /**
     * @description Are there active Rollup__mdt records for the job type?
     * @return True if there are active Rollup__mdt records for the current job type
     */
    protected Boolean hasActiveRollupsForThisJob() {
        Boolean hasActiveRollups = false;
        if (this.jobType == CRLP_RollupProcessingOptions.RollupType.GAU) {
            hasActiveRollups = CRLP_Rollup_SVC.hasActiveRollupsForSObject(General_Accounting_Unit__c.SObjectType);

        } else if (this.jobType == CRLP_RollupProcessingOptions.RollupType.AccountHardCredit) {
            hasActiveRollups = CRLP_Rollup_SVC.hasActiveRollupsForSObject(Account.SObjectType);

        } else if (this.jobType == CRLP_RollupProcessingOptions.RollupType.AccountSoftCredit) {
            hasActiveRollups = CRLP_Rollup_SVC.hasActiveAccountSoftCreditRollupsForSObject(Account.SObjectType);

        } else if (this.jobType == CRLP_RollupProcessingOptions.RollupType.ContactHardCredit) {
            hasActiveRollups = CRLP_Rollup_SVC.hasActiveRollupsForSObject(Contact.SObjectType);

        } else if (this.jobType == CRLP_RollupProcessingOptions.RollupType.ContactSoftCredit) {
            hasActiveRollups = CRLP_Rollup_SVC.hasActivePartialSoftCreditRollupsForSObject(Contact.SObjectType);

        } else if (this.jobType == CRLP_RollupProcessingOptions.RollupType.AccountContactSoftCredit) {
            hasActiveRollups = CRLP_Rollup_SVC.hasActivePartialSoftCreditRollupsForSObject(Account.SObjectType);

        } else if (this.jobType == CRLP_RollupProcessingOptions.RollupType.RecurringDonations) {
            hasActiveRollups = CRLP_Rollup_SVC.hasActiveRollupsForSObject(npe03__Recurring_Donation__c.SObjectType);
        }
        return hasActiveRollups;
    }

    /** @description Are there Payment rollups to execute? */
    private Boolean hasPaymentRollups = null;
    public Boolean hasActivePaymentRollupsForThisJob() {
        if (hasPaymentRollups == null) {
            this.hasPaymentRollups = CRLP_Rollup_SVC.hasActivePaymentRollupsForSObject(this.summaryObjectType);
        }
        return hasPaymentRollups;
    }

    /********************************************************************************************************
     * @description Soft Credit roll-ups work by querying the OCR object as the main object, but sending
     * PartialSoftCredit records as the detail records for the rollups. This is because PSC has a custom field
     * for Amount and generally the rule is that every Donation has an OCR record, but may or may not have a PSC
     * record. This method creates non-committed PartialSoftCredit records where one doesn't already exist to
     * use for the rollups process.
     * @param detailRecords List<OpportunityContactRole>
     * @return List<Partial_Soft_Credit__c>
     */
    protected List<Partial_Soft_Credit__c> buildPartialSoftCreditRecordsFromOCRs(List<OpportunityContactRole> detailRecords) {
        List<Id> oppIds = getParentIdsFromDetailRecords(detailRecords, 'OpportunityId');
        List<Id> contactIds = getParentIdsFromDetailRecords(detailRecords, 'ContactId');

        String oppQuery = CRLP_Query_SEL.buildDetailObjectQueryForRollup(Opportunity.SObjectType,
                new List<SObjectType>{ OpportunityContactRole.SObjectType, Partial_Soft_Credit__c.SObjectType }) +
                ' WHERE Id IN :oppIds';
        Map<Id, Opportunity> oppsMapById = new Map<Id, Opportunity>((List<Opportunity>)database.query(oppQuery));

        List<Partial_Soft_Credit__c> pscDetailRecords = new List<Partial_Soft_Credit__c>();

        for (OpportunityContactRole ocr : detailRecords) {
            Opportunity opp = oppsMapById.get(ocr.OpportunityId);

            // Find the matching PartialSoftCredit record for the OCR record; if there is one
            Partial_Soft_Credit__c matchedPSC;
            for (Partial_Soft_Credit__c psc : opp.Partial_Soft_Credits__r) {
                if (psc.Contact__c == ocr.ContactId) {
                    matchedPSC = psc.clone(true, true, true, true);
                    matchedPSC.Opportunity__r = opp;
                    break;
                }
            }
            if (matchedPSC == null) {
                // If there is no matched PartialSoftCredit record for this OCR, create a new one (not committed)
                // and set the Amount to the full Amount value from the Opportunity record.
                matchedPSC = new Partial_Soft_Credit__c(
                        Opportunity__c = opp.Id,
                        Opportunity__r = opp,
                        Contact__r = ocr.Contact,
                        Contact__c = ocr.ContactId,
                        Contact_Role_ID__c = ocr.Id,
                        Role_Name__c = ocr.Role,
                        Amount__c = opp.Amount
                );
                if (UserInfo.isMultiCurrencyOrganization()) {
                    matchedPSC.put('CurrencyIsoCode', opp.get('CurrencyIsoCode'));
                }
            }
            pscDetailRecords.add(matchedPSC);
        }

        return pscDetailRecords;
    }

    /**
     * @description Produces the where clause that should be used for the inner join
     * @return The WHERE clause, as a string, that should be used to filter the detail records
     */
    @TestVisible protected String getMainQueryInnerJoinFilter() {
        String whereClause = null;
        Customizable_Rollup_Settings__c customizableRollupSettings = UTIL_CustomSettingsFacade.getCustomizableRollupSettings();
        Boolean hasMaxValuesForIncrementalMode = (maxDaysAgo != null || maxYearsAgo != null);

        if (getIsIncrementalModeEnabled() && hasMaxValuesForIncrementalMode) {
            whereClause = buildIncrementalModeWhereClause();
        } else {
            if (customizableRollupSettings.Disable_Related_Records_Filter__c == false) {
                whereClause = buildNonIncrementalModeWhereClause();
            }
        }
        return whereClause;
    }

    /******************************** Helper Methods *****************************/

    /**
     * @description Produces the where clause that should be used for the inner join when NOT in incremental mode
     * @return The WHERE clause, as a string, that should be used to filter the detail records
     */
    private String buildNonIncrementalModeWhereClause() {
        String whereClause = null; //will return null if this method is called from an unsupported rollup type

        switch on (jobType) {

            when AccountHardCredit, ContactHardCredit {
                whereClause = 'Id IN (' +
                        'SELECT ' + keyField + ' ' +
                        'FROM ' + detailObjectType + ')';
            }

            when ContactSoftCredit {
                whereClause = 'Id IN (SELECT ContactId FROM OpportunityContactRole)';
            }

            when AccountContactSoftCredit, AccountSoftCredit {
                // It's not possible to do an inner query on this due to the following Salesforce error:
                // "The inner select field 'Contact.AccountId' cannot have more than one level of relationships"
            }

            when RecurringDonations {
                whereClause = 'Id IN (SELECT npe03__Recurring_Donation__c FROM Opportunity)';
            }
        }

        return whereClause;
    }

    /**
     * @description Produces the where clause that should be used for the inner join when in incremental mode
     * @return The WHERE clause, as a string, that should be used to filter the detail records
     */
    private String buildIncrementalModeWhereClause() {
        String whereClause = 'Id IN (' +
                'SELECT ' + keyField + ' ' +
                'FROM ' + detailObjectType + ' ' +
                'WHERE ';

        if (hasIncrementalFieldOverrides) {
            whereClause += overrideForLastNDaysField + ' >= LAST_N_DAYS:' + overrideForLastNDaysValue;
        } else {
            // Set to CloseDate for testing, SystemModstamp for prod.
            String whereClauseDateField = Test.isRunningTest() ? 'CloseDate' : 'SystemModstamp';
            whereClause += whereClauseDateField + ' ';

            if (maxDaysAgo != null && maxYearsAgo != null) {
                if ((maxDaysAgo / 365) > maxYearsAgo) {
                    whereClause += '>= LAST_N_DAYS:' + maxDaysAgo;
                } else {
                    whereClause += '>= LAST_N_YEARS:' + maxYearsAgo;
                }
            } else if (maxDaysAgo != null) {
                whereClause += '>= LAST_N_DAYS:' + maxDaysAgo;
            } else if (maxYearsAgo != null) {
                whereClause += '>= LAST_N_YEARS:' + maxYearsAgo;
            }
        }
        return whereClause += ')';
    }

    /**
     * @description The max Integer for all active time-bound Days_Back rollups,
     * or null if there are no active time-bound Days_Back rollups for this summary object
     */
    private Integer maxDaysAgo {
        get {
            if (maxDaysAgo == null) {
                maxDaysAgo = getMaxIntegerValueFromRollupsForType(CRLP_Operation.TimeBoundOperationType.Days_Back);
            }
            return maxDaysAgo;
        }
        private set;
    }

    /**
     * @description The max Integer for all active time-bound Years_Ago rollups,
     * or null if there are no active time-bound Years_Ago rollups for this summary object
     */
    private Integer maxYearsAgo {
        get {
            if (maxYearsAgo == null) {
                maxYearsAgo = getMaxIntegerValueFromRollupsForType(CRLP_Operation.TimeBoundOperationType.Years_Ago);
            }
            return maxYearsAgo;
        }
        private set;
    }

    /**
     * @description Returns the maximum integer for time-bound rollups by time-bound type
     * @param timeBoundType Time-bound type for which the max integer should be calculated
     * @return max integer for the specified time bound type
     */
    private Integer getMaxIntegerValueFromRollupsForType(CRLP_Operation.TimeBoundOperationType timeBoundType) {
        Integer maxInteger = null;
        for (Rollup__mdt rollup : statefulCacheOfRollupsToBeProcessed) {
            if (rollup.Active__c == true
                    && String.isNotBlank(rollup.Time_Bound_Operation_Type__c)
                    && rollup.Time_Bound_Operation_Type__c == timeBoundType.name()
                    && rollup.Integer__c != null) {
                if (maxInteger == null || rollup.Integer__c > maxInteger) {
                    maxInteger = (Integer) rollup.Integer__c;
                }
            }
        }
        return maxInteger;
    }

    /**
     * @description Determines whether the rollup should be run in incremental mode
     * @param jobType the type of rollup job
     * @return true if the rollup should be run in incremental mode, otherwise false
     */
    private Boolean getIsIncrementalModeEnabled() {
        if (isScheduledJob == null || isScheduledJob == false) {
            return false;
        }

        Customizable_Rollup_Settings__c customizableRollupSettings =
                UTIL_CustomSettingsFacade.getCustomizableRollupSettings();

        switch on (jobMode) {

            when NonSkewMode {

                switch on (jobType) {

                    when AccountHardCredit {
                        return customizableRollupSettings.AccountHardCreditNonSkew_Incremental__c;
                    }

                    when ContactHardCredit {
                        return customizableRollupSettings.ContactHardCreditNonSkew_Incremental__c;
                    }

                    when else {
                        return false;
                    }
                }
            }

            when else {
                return false;
            }
        }
    }

    /**
     * @description Returns true if the org has configured a
     * user-defined inner join for incremental rollups
     */
    private Boolean hasIncrementalFieldOverrides {
        get {
            return overrideForLastNDaysField != null && overrideForLastNDaysValue != null;
        }
    }

    /**
     * @description Value to use with LAST_N_DAYS: in the inner join query
     * when the org has the user-defined inner join for incremental rollups
     */
    private Integer overrideForLastNDaysValue {
        get {
            if (overrideForLastNDaysValue == null) {
                Customizable_Rollup_Settings__c customizableRollupSettings =
                        UTIL_CustomSettingsFacade.getCustomizableRollupSettings();

                if (customizableRollupSettings.Rollups_IncrementalLastNDays_ValOverride__c != null) {
                    overrideForLastNDaysValue = (Integer) customizableRollupSettings.Rollups_IncrementalLastNDays_ValOverride__c;
                }
            }
            return overrideForLastNDaysValue;
        }
        set;
    }

    /**
     * @description API name of the date field to use as in the inner join query
     * when the org has the user-defined inner join for incremental rollups
     */
    private String overrideForLastNDaysField {
        get {
            if (overrideForLastNDaysField == null) {
                Customizable_Rollup_Settings__c customizableRollupSettings =
                        UTIL_CustomSettingsFacade.getCustomizableRollupSettings();

                if (String.isNotBlank(customizableRollupSettings.Rollups_IncrementalLastNDays_FldOverride__c)) {
                    overrideForLastNDaysField = customizableRollupSettings.Rollups_IncrementalLastNDays_FldOverride__c;
                }
            }
            return overrideForLastNDaysField;
        }
        set;
    }

    /*******************************************************************************************************
     * @description CRLP Batch Job custom exception
     */
    public class CRLPBatchException extends Exception {}

    /*******************************************************************************************************
     * @description Shared method to log an Error record when a CRLP Batch is skipped because
     * the previous job hadn't yet completed
     * @param className The name of the skipped batch class to be used in the error message
     */
    public void logDuplicateBatchError(String className) {

        CRLPBatchException ex = new CRLPBatchException();
        ex.setMessage(String.format(Label.CRLP_BatchSkipped, new List<String>{className}));
        ERR_Handler.processError(ex, ERR_Handler_API.Context.CRLP);

    }

}